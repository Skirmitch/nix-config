{ pkgs, ... }:
let
  # Referenced as a store path rather than wrapped: `ExecStart` gets
  # ${pkgs.python3}/bin/python3 ${./scripts/tmp-sweep.py}, which copies the
  # script into the store on its own and needs no shebang rewriting, no
  # writePython3Bin, and no flake8 pass over a 150-line diagnostic.
  sweeper = ./scripts/tmp-sweep.py;
in
{
  # --- Bound /tmp against the `nix develop` + pytest tmp_path leak ---
  #
  # 2026-10-23: `/` hit 93% (850 G of 931 G). 221 G of that was /tmp, and
  # 197.6 GiB of THAT was 2,335 /tmp/nix-shell.* directories accumulated in six
  # days. Mechanism: `nix develop` sets TMPDIR=/tmp/nix-shell.XXXXXX, pytest's
  # tmp_path factory honours TMPDIR, so pytest-of-skirmitch/pytest-N lands
  # inside a dir that only survives a CLEAN exit - and pytest's own
  # "keep the last 3" retention never fires because every run gets a fresh base.
  # `nix shell` sets no TMPDIR and is NOT a producer; the idiom in the global
  # CLAUDE.md is innocent. systemd-tmpfiles' `q /tmp ... 10d` was the only
  # existing bound, and at ~33 GiB/day that permits ~330 GiB.
  #
  # This is the LAYER THAT CANNOT BREAK ANYONE: it needs no seat restart, no
  # project repo change, and no environment variable to propagate. It cleans up
  # after the leak rather than preventing it. The prevention half
  # (PYTEST_DEBUG_TEMPROOT) is below, enabled 2026-10-24.
  #
  # Confirmed disposable by all five seats that run suites (Operator, Builder,
  # Kuramori, Archivist, Lonchera), each with its own negative control - none of
  # them reads a tmp_path artifact after a run.
  systemd.user.services.tmp-sweep = {
    Unit = {
      Description = "Reclaim leaked nix-develop/pytest temp dirs from /tmp";
      Documentation = "file://${toString sweeper}";
    };
    Service = {
      Type = "oneshot";
      # 240 min, not the 120 the tool defaults to: this runs unattended, and
      # Kuramori's mamori batches and the hc-sync store suite (~429 s) are long.
      # The margin costs nothing - growth is bounded either way.
      ExecStart = "${pkgs.python3}/bin/python3 ${toString sweeper} --delete --min-age 240";
      # It must never compete with the work it is cleaning up after.
      Nice = 19;
      IOSchedulingClass = "idle";
      CPUWeight = 1;
      MemoryMax = "256M";
      # The sweeper's own guards are the real safety (refuses any dir held as a
      # cwd or an open fd, uses the newest mtime anywhere in the subtree, and
      # re-checks immediately before each unlink). These are belt-and-braces so
      # a bug in it cannot reach anything but /tmp.
      PrivateNetwork = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [ "/tmp" ];
      NoNewPrivileges = true;
    };
  };

  systemd.user.timers.tmp-sweep = {
    Unit.Description = "Hourly reclaim of leaked /tmp/nix-shell.* dirs";
    Timer = {
      OnBootSec = "15min";
      OnUnitActiveSec = "1h";
      # Without this a laptop/desktop that was asleep skips the run entirely.
      Persistent = true;
      AccuracySec = "5min";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # --- LAYER 2: the actual fix, ENABLED 2026-10-24 ---
  #
  # Setting PYTEST_DEBUG_TEMPROOT to a stable root gives pytest ONE base across
  # runs, so its own keep-last-3 retention starts working (measured: 5 runs ->
  # 3 retained dirs). Verified in _pytest/tmpdir.py that it outranks TMPDIR
  # unconditionally and that only --basetemp beats it.
  #
  # WHY LAYER 1 ALONE IS NOT ENOUGH, measured over the sweep's first 15 h:
  # it reclaimed 43.7 GiB across 16 runs with 0 failures, and /tmp STILL drifted
  # 27 G -> 39 G. So real inflow is ~3.7 GiB/h = ~89 GiB/day - nearly 3x the
  # 33 GiB/day the original six-day average implied, which means the 189 GiB
  # recovered on 10-23 would refill in about two days, not six. The hourly sweep
  # bounds the leak without winning against it: --min-age 240 guarantees a
  # standing floor (37 dirs, ages min 77 / median 226 / max 332 min), and most
  # of those are the ~1.1 GiB pytest payloads. Roughly 33 of the 39 GB is
  # exactly what this variable relocates - onto a different physical disk
  # (/mnt/bulk is nvme2n1p1; / is nvme1n1p2), which also moves that write load
  # off the device the stall probe measures at 6.35% full io stall.
  #
  # KURAMORI'S VERIFICATION, 2026-10-24, which is what unblocked this: mamori's
  # WHOLE suite at tip e21cef7 under this root - 5315 passed, 1 skipped, 497 s,
  # identical counts to under /tmp/nix-shell.*. It forced a 5-digit run number
  # by pre-creating pytest-99998, which is the only way the path budget is
  # answerable. Longest AF_UNIX bind came to 97 bytes of the 107 sun_path
  # allows. pytest truncates the test-dir name to 30 chars, so the ONLY
  # remaining growth vector is the run number at 1 byte per digit: 10 spare
  # bytes buys run numbers up to 15 digits. No cross-device rename failures with
  # TMPDIR on / and tmp_path on bulk.
  #
  # NOT COVERED, and this needs the seat rather than nix: mamori's gitleaks
  # wrapper makes its `mamori-gate-*` dirs with tempfile, which follows TMPDIR,
  # not this variable. Kuramori's ruling A102 removes them at exit. The hourly
  # sweep above catches the containing nix-shell dir as a second layer, but only
  # once the 240 min hold expires, so A102 is the better mechanism of the two.
  #
  # Do NOT use --basetemp: pytest REMOVES AND RECREATES that directory at
  # session start (measured - a canary from run 1 was destroyed by run 2), so a
  # shared one would have concurrent suites wiping each other mid-run.
  #
  # INERT UNTIL A FRESH LOGIN SESSION - stronger than "login shells only", and
  # measured 2026-10-24 rather than assumed. home.sessionVariables is delivered
  # by ~/.profile sourcing hm-session-vars.sh, and that file opens with:
  #
  #     if [ -n "${__HM_SESS_VARS_SOURCED-}" ]; then return; fi
  #
  # That marker is exported into the environment and therefore INHERITED by
  # every descendant. The graphical session already carries it (verified: kgx
  # itself has __HM_SESS_VARS_SOURCED=1, XCURSOR_THEME and LOCALE_ARCHIVE_2_27
  # in its own environ, and hands them to each shell it spawns, which are not
  # even login shells). So the guard fires in anything launched from the running
  # session and the new generation's file is never read.
  #
  # Proven by control: `env -u XCURSOR_THEME bash -lc 'printenv XCURSOR_THEME'`
  # comes back EMPTY - a login shell that did not re-source - while
  # `env -u __HM_SESS_VARS_SOURCED -u XCURSOR_THEME bash -lc ...` restores it.
  #
  # CONSEQUENCE: a new terminal is not enough, and RESTARTING A SEAT IS NOT
  # ENOUGH. It needs a logout/login or a reboot. Until then nothing changes,
  # which is why enabling it cannot disturb a suite mid-run.
  #
  # To check the generation without logging out:
  #     env -u __HM_SESS_VARS_SOURCED bash -lc 'printenv PYTEST_DEBUG_TEMPROOT'
  # A bare `printenv` in an existing shell will show nothing and that is NOT
  # evidence of failure. Note also that a reboot PARKS /tmp into old_roots
  # (impermanence, keep 2), so clear /tmp before rebooting for this.
  #
  # /mnt/bulk/pytest-tmp must stay HAND-MADE on the mounted volume. Never add a
  # tmpfiles.d rule or an activation `mkdir -p` for it: /mnt/bulk is `nofail`,
  # so if the mount were absent such a rule would create the directory on `/`
  # under the empty mountpoint and silently restore this exact leak, hidden
  # under the mount when it returned. With no rule, a missing mount fails loudly
  # at session start, which is the behaviour we want. Verified 2026-10-24 that
  # the directory is on st_dev 36 == /mnt/bulk, not on / (st_dev 22).
  home.sessionVariables.PYTEST_DEBUG_TEMPROOT = "/mnt/bulk/pytest-tmp";
}
