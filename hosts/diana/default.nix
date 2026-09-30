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
      # 32G -> 64G, 2026-09-29. JL offered double or +50% and Operator chose double.
      # THE MEASURED CASE: at 13:10-13:30 this subvolume hit 33G against the 32G wall and
      # agents in seven concurrent toolbox lanes died with [Errno 122]; several mutation
      # and redtest runs were voided and re-run.
      #
      # BUT read Operator's own accounting before reading that as "32G was too small":
      # 16G freed at 13:35 and 11.4G at 15:00, ALL of it scratch belonging to agents that
      # had ALREADY RETURNED. 27.4G of the 33G was garbage. By their own words, "32G would
      # likely have held today" with the cleanup step they are now adding - when a
      # Workflow returns and its results are persisted, its agents' scratch is deleted.
      #
      # So the wall did its job: it caught uncollected garbage, which is exactly what JL
      # built it for. Doubling is headroom for genuine growth - seven concurrent lanes,
      # each agent copying 0.5-4G trees, and a parallel suite runner still to come - NOT a
      # substitute for collecting it. 64G is 11% of the 586G free on the bulk disk, so the
      # quota keeps its real job: catching a runaway long before it fills the device.
      scratchQuota = "64G"; scratchAlarm = "32G";
      memoryMax = "22G"; memorySwapMax = "4G"; tasksMax = 8192;
      # JL's walk item 7, 2026-09-27: the live repos are READ-ONLY for this seat. Its
      # gate enumerates spellings of a write and never converges; the kernel does not
      # enumerate. Builder's list stays empty - he merges and pushes in here.
      # Read-only for the OPERATOR seat only, at the kernel, via the bwrap ro-binds
      # the launcher applies. The Builder keeps full write on all three: he has
      # readOnly = [ ] and therefore no bwrap wrapper at all, so this cannot reach him.
      #
      # JL's ruling, 2026-09-30T13:58:45Z, typed: "a, ur recommendation", against an
      # either/or that named option (a) as "lock those two folders read-only for my
      # seat at the OS level, the way the repos already are, then swap". Verified in
      # the primary transcript, not taken from the relay: dccf885b...jsonl line 132375,
      # type=user, promptSource=typed, origin.kind=human, sha256(text) de6ee16b7236f0db,
      # with the options at 132299 and re-posted at 132322.
      #
      # WHY the two new ones. Operator is swapping in a new op-gate that is safer on
      # everything its safety rules can read, but 24 file-writing command shapes are
      # blocked today only BY ACCIDENT - the same command also asks a question the old
      # gate refuses on sight, and the new gate answers it instead. repos was already
      # locked, so it is unaffected; these two were the only estate roots the operator
      # seat could still write. A kernel lock catches every shape, including ones nobody
      # has found, which a parser cannot promise. Operator scanned 786 of its own tool
      # files: none writes into either root, so the lock breaks nothing it runs. JL chose
      # lock-then-swap, so the gate swap waits on this landing.
      #
      # NOT INCLUDED: /home/skirmitch/closure-worktrees (8.2 GiB, 24 entries). The
      # ruling names the Builder's folder and his build worktrees; closure-worktrees is
      # where the operator's OWN mutant lane clones from, so locking it would likely
      # break the requester. Raised with Operator rather than assumed either way.
      readOnlyPaths = [
        "/home/skirmitch/lonchera/repos"
        "/home/skirmitch/cycle-hq/Builder"
        "/home/skirmitch/lonchera/worktrees"
      ];
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
