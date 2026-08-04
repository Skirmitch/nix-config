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
    memoryPercent = 100;   # LOGICAL cap (= 64 GiB uncompressed); real RAM cost
                           # is the compressed size and only grows under pressure
    priority = 100;        # > the disk swapfile's 10 => kernel fills zram first
  };

  # 2. disk swapfile — deep backstop on the subvol that survives the wipe
  swapDevices = [{
    device = "/persist/swapfile";
    size = 32768;          # MiB => 32 GiB (out of 366 GiB free)
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
