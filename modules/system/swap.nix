{ ... }:
# --- MEMORY-PRESSURE / OOM CUSHION ---
#
# Diana runs Claude Code sessions that fan out into hundreds of node/CLI
# subagents (100s of MiB each). With 64 GB RAM and — until now — ZERO swap and
# no userspace OOM daemon, a stampede exhausted RAM and the box hard-froze:
# the kernel had nowhere to shed cold pages, fell into direct-reclaim thrash,
# and livelocked *before* the in-kernel OOM killer ever fired cleanly.
#
# This is a four-layer cushion, not just "add swap". Each layer was verified
# against the flake's pinned nixpkgs (config/zram.nix, config/swap.nix,
# services/system/earlyoom.nix) — see memory: diana-swap-cushion.
#
#   1. zram   — fast compressed in-RAM swap; the primary shed target. A burst
#               of anonymous JS/JSON heap compresses ~3x (zstd), so the kernel
#               relieves pressure at RAM speed instead of thrashing. Highest
#               priority => filled first.
#   2. disk   — a 32 GiB btrfs swapfile on /persist (survives the impermanence
#               @root wipe; @persist is never snapshotted). Lower priority =>
#               only absorbs overflow / genuinely cold + incompressible pages.
#               NoCOW is handled FOR us: the swap module sees /persist is btrfs
#               and runs `btrfs filesystem mkswapfile`, which creates the file
#               already NODATACOW + preallocated + mkswap'd. /persist is a live
#               mountpoint so the btrfs branch's missing `mkdir -p` never bites.
#   3. earlyoom — the actual anti-freeze valve. systemd-oomd ships enabled but
#               is INERT here (no ManagedOOM=kill on the user slice, and it
#               needs swap). earlyoom polls free RAM+swap directly (no cgroups,
#               no PSI needed), and SIGTERMs the fattest offender before either
#               is exhausted. `-g` kills the victim's whole process GROUP, so a
#               runaway loses its entire subagent fork-tree, not one node proc;
#               --prefer biases the cull toward node/claude, --avoid shields the
#               desktop + sshd so the box stays usable and reachable.
#   4. sysctl — tuned for a zram-first box: high swappiness (paging to
#               compressed RAM is cheaper than evicting hot file cache),
#               page-cluster 0 (readahead is pointless for RAM-backed swap),
#               and an earlier kswapd wake so reclaim ramps before a burst
#               outruns it.
#
# systemd-oomd is deliberately left as-is (not put on user slices — it would
# evict the whole desktop session; earlyoom's process granularity is correct
# for this workload). The old nvme0n1p4 swap partition on the Windows disk is
# intentionally NOT used.
{
  # 1. zram — primary, compressed, in-RAM
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;   # LOGICAL cap (= 64 GiB uncompressed). This is the size
                           # the kernel advertises, NOT what zram costs in RAM.
    priority = 100;        # > the disk swapfile's 10 => kernel fills zram first

    # Bound on how much RAM zram can ever cost. Unset (null) means the device is
    # sized at 100% of RAM with no bound at all, which is what took the box down
    # on 2026-09-22 and is the most important line in this file.
    #
    # READ WHAT THIS OPTION ACTUALLY DOES before changing it. `memoryMax` caps
    # `zram-size` in the generated zram-generator.conf, i.e. the LOGICAL disksize
    # - the same dimension `memoryPercent` sets. It does NOT write
    # /sys/block/zram0/mem_limit. Verified by building and reading the file:
    #     before:  zram-size=100 / 100 * ram
    #     after:   zram-size=min(100 / 100 * ram, 25769803776 / 1024 / 1024)
    # It still bounds physical RAM, but indirectly: a device that can only hold
    # 24 GiB of logical pages cannot cost more than 24 GiB of physical RAM even
    # at 1:1 compression.
    #
    # THE HOLE IT CLOSES. The reasoning this replaces was "real RAM cost is the
    # compressed size and only grows under pressure". True, and unbounded. zstd
    # gives ~3x on the JS/JSON heap this module was written for, so a full 61.9
    # GiB zram costs ~20 GiB and nothing bad happens. But compression ratio is a
    # property of the DATA. Already-compressed archives, binaries, encrypted
    # bytes and model weights return ~1:1, and then 61.9 GiB of logical zram
    # costs up to 61.9 GiB of PHYSICAL RAM on a 61 GiB machine: the swap device
    # installed to prevent a freeze becomes the cause of one.
    #
    # Measured on 2026-09-22, the only event that actually downed this machine:
    #   15:43:45  fresh boot   mem 99.91% free, swap 100.00% free
    #   16:13:12  +29m27s      mem  4.79% free, swap   4.96% free
    # ~57 GiB RAM and ~91 GiB swap in under 30 minutes. earlyoom's own "user mem
    # total" fell from 59477 MiB to 37511 MiB during it - 22 GiB of RAM swallowed
    # by zram holding compressed pages. That is why the largest victim earlyoom
    # could find was 134 MiB: the memory was not in any process, it was in the
    # swap device. Killing a 134 MiB process against a deficit that size is
    # futile, and the second kill returned "kill failed: Timer expired" because
    # the box could no longer schedule its own victim's death.
    #
    # WHY 24 GiB, AND WHAT IT COSTS. Worst case (incompressible) zram now costs
    # 24 GiB, leaving a hard floor of ~37 GiB of RAM it can never touch - enough
    # for earlyoom to actually schedule a kill, which is precisely what failed on
    # 09-22. The honest cost: on compressible data we now get 24 GiB of zram swap
    # instead of 61.9 GiB, so total swap falls from ~94 GiB to ~56 GiB (24 zram +
    # 32 disk). That is deliberate. Hitting the swap wall earlier, while RAM is
    # still healthy, is the good failure: earlyoom fires with room to work
    # instead of livelocking. A 100%-of-RAM zram device was always aggressive;
    # this lands at ~39%.
    #
    # IF WE LATER WANT BOTH - full 61.9 GiB logical AND a hard physical ceiling -
    # that needs a udev rule or oneshot writing 24 GiB to /sys/block/zram0/mem_limit,
    # because zram-generator exposes no mem_limit setting. Not done: more moving
    # parts than the problem currently justifies.
    #
    # This is a system-level fix, not a per-seat cap. It stops the machine going
    # down without constraining any agent's legitimate work by one byte.
    memoryMax = 24 * 1024 * 1024 * 1024;
  };

  # 2. disk swapfile — deep backstop on the subvol that survives the wipe
  swapDevices = [{
    device = "/persist/swapfile";
    # 128 GiB. Raised from 32 GiB on 2026-09-27 by JL's ruling, which is worth stating
    # because it inverts the usual instinct:
    #
    #   "If Operator and/or Builder can indeed use more ram to go faster/more parallel,
    #    the answer is to buy ram, NOT to cripple them. For legitimate work fanned out,
    #    it means I need to increase the pc size... Increasing swap first while I buy ram."
    #
    # So hitting a memory ceiling through LEGITIMATE fan-out is not a fault to be capped,
    # it is a signal that the machine is undersized. The seats' ceilings exist to catch
    # uncollected garbage and leaks and to stop the box dying - never to ration real work.
    # Until more RAM is in the box, disk swap is the cheap way to buy headroom.
    #
    # DISK swap, specifically, is the SAFE kind to grow. zram's compressed pages live in
    # physical RAM, so growing zram grows the thing that killed the machine on 09-22.
    # A swapfile costs only disk: 128 GiB out of 617 GiB free. Combined with the 24 GiB
    # zram cap above, total swap goes from ~94 GiB to ~152 GiB while the worst-case RAM
    # that swap can consume FALLS from 61.9 GiB to 24 GiB. More headroom and less risk,
    # which is not a trade - it is the previous configuration having been wrong.
    #
    # NOTE FOR WHOEVER CHANGES THIS NUMBER: the NixOS swap module does not grow a
    # swapfile in place. When `size` differs from the file on disk it runs `rm -f` and
    # recreates it with `btrfs filesystem mkswapfile` (config/swap.nix:299-303). Apply
    # with `nixos-rebuild boot` and reboot, never `switch`, so the file is rebuilt while
    # swap is off rather than underneath a running system.
    size = 131072;         # MiB => 128 GiB (out of 617 GiB free)
    priority = 10;         # below zram; overflow / cold-page reservoir only
  }];

  # 3. earlyoom — graceful, process-granular kill before the freeze
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;      # SIGTERM biggest matching proc under 5% free RAM
    freeSwapThreshold = 10;    # ...once swap is also nearly full
    # *KillThreshold default to half of the above => SIGKILL at 2.5% / 5%
    enableNotifications = true;  # desktop toast naming the sacrificed process
    extraArgs = [
      "-g"                                                     # kill the whole process group (subagent tree)
      "--prefer" "(^|/)(node|claude)$"                        # bias the cull toward the stampede
      "--avoid" "(^|/)(systemd|Xorg|gnome-shell|gnome-session|sshd|dbus-broker|pipewire|wireplumber|vivaldi)$"
    ];
  };

  # 4. VM reclaim tuning for zram-first
  boot.kernel.sysctl = {
    "vm.swappiness" = 180;              # prefer cheap zram over evicting file cache (kernel allows 0-200 w/ swap)
    "vm.page-cluster" = 0;             # 1 page per swap-in; readahead is pure overhead for RAM-backed swap
    "vm.watermark_scale_factor" = 125; # wake kswapd earlier so reclaim starts before the burst outruns it
  };
}
