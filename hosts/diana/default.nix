{ nixosLabel, pkgs, ... }: {
  imports = [
    ./hardware.nix
    ./impermanence.nix
    ../../modules/core
    ../../modules/system/boot.nix
    ../../modules/system/graphics.nix
    ../../modules/system/nvidia.nix
    ../../modules/system/audio.nix
    ../../modules/system/networking.nix
    ../../modules/system/tailscale.nix
    ../../modules/system/nordvpn.nix
    ../../modules/system/vpn-hotspot.nix
    ../../modules/system/hotspot.nix
    ../../modules/system/fonts.nix
    ../../modules/system/input.nix
    ../../modules/system/users.nix
    ../../modules/system/swap.nix
    ../../modules/system/bulk-storage.nix
    ../../modules/system/cooling.nix
    ../../modules/gaming
    ../../modules/apps/claude.nix
    ../../modules/apps/docker.nix
    ../../modules/apps/postgresql.nix
    ../../modules/apps/cycle-seats.nix
    ../../modules/apps/redis.nix
    ../../modules/apps/programming.nix
    ../../modules/apps/printing3d.nix
    ../../modules/apps/freecad.nix
    ../../modules/apps/cad-tools.nix
    ../../modules/apps/vr.nix
    ../../modules/apps/sunshine.nix
    ../../modules/apps/remote-desktop.nix
    ../../modules/apps/immersed.nix
    ../../modules/apps/on1-photoraw.nix
    ../../modules/apps/zerene-stacker.nix
    ../../modules/apps/g9cam.nix
    ../../modules/apps/health-store.nix
  ];

  # --- CYCLE-HQ SEATS ---
  # One table. Postgres roles, the drop-timer exemption, redis instances, slices, the
  # `seat` launcher, the SessionStart hook, the sweep and /etc/cycle/seats.json all derive
  # from here, so adding a seat is one attribute rather than six edits that can disagree.
  #
  # MEMORY NUMBERS ARE NOW MEASURED, not argued. Both seats sampled memory.stat anon at
  # 1 s through their heaviest routine job on 2026-09-27:
  #
  #   operator  full suite, 141 checks, 653 s:  anon idle 469 MiB, PEAK 731 MiB, END 404 MiB
  #                                             - it finished 65 MiB BELOW where it started.
  #                                             Largest single process 278 MiB. PSI 0.00.
  #   builder   backend suite, 2506 tests -n 8: anon PEAK 2.88 G, released to 1.78 G.
  #   cycle.slice with BOTH seats working:      anon 2.5 GiB, 220 tasks.
  #
  # So 22G per seat is 7x Builder's measured peak and 30x Operator's. These are not
  # governors. Per JL, 2026-09-27: if the seats can use more RAM to go faster, the answer
  # is to buy RAM, not to cap them - a seat hitting a ceiling through LEGITIMATE fan-out is
  # a signal that the machine is undersized, and he wants to hear it.
  #
  # 22G each is chosen so 22+22=44 sits strictly under the 48G parent. That is Builder's
  # invariant: if the seats can sum past the parent, the PARENT's OOM fires first, and a
  # memcg OOM picks the worst task in the whole subtree - so one seat's runaway kills the
  # other seat's orchestrator. Containment costs nothing here because the real peaks are
  # under 3 GiB.
  #
  # THE SEATS OWN THESE FROM HERE. A drop-in at
  # ~/.config/systemd/user/cycle-<seat>.slice.d/override.conf beats this file without a
  # rebuild; `cycle-limits` prints what is in force and fails if the invariant breaks.
  cycle.seats = {
    operator = {
      folder = "cycle-hq/Operator";
      dbRole = "lonchera_operator";
      redisPort = 6380;
      scratchQuota = "32G"; scratchAlarm = "16G";
      memoryMax = "22G"; memorySwapMax = "4G"; tasksMax = 8192;
    };
    builder = {
      folder = "cycle-hq/Builder";
      dbRole = "lonchera_builder";
      redisPort = 6381;
      scratchQuota = "20G"; scratchAlarm = "10G";
      memoryMax = "22G"; memorySwapMax = "4G"; tasksMax = 8192;
    };
  };

  networking.hostName = "Diana";

  # ASUS motherboard EC sensors
  boot.kernelModules = [ "asus_ec_sensors" ];

  # Was pinned to 7.0.5: 7.0.8 regressed MT7921U BT (WMT func ctrl -22 on
  # init). Fixed upstream ("btmtk: accept too short WMT FUNC_CTRL events"),
  # present in 7.0.11 — unpinned 2026-06-08.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  system.nixos.label = nixosLabel;
  system.stateVersion = "25.11";
}
