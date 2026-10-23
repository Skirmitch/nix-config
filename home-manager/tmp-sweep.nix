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
  # (PYTEST_DEBUG_TEMPROOT) is below, deliberately still off.
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

  # --- LAYER 2, DELIBERATELY NOT ENABLED YET ---
  #
  # Setting PYTEST_DEBUG_TEMPROOT to a stable root is the actual fix: it gives
  # pytest ONE base across runs, so its own keep-last-3 retention starts working
  # (measured: 5 runs -> 3 retained dirs). Verified in _pytest/tmpdir.py that it
  # outranks TMPDIR unconditionally and that only --basetemp beats it.
  #
  # Do NOT use --basetemp: pytest REMOVES AND RECREATES that directory at
  # session start (measured - a canary from run 1 was destroyed by run 2), so a
  # shared one would have concurrent suites wiping each other mid-run.
  #
  # Two reasons it is still off:
  #   1. Kuramori has an open condition - mamori binds AF_UNIX sockets inside
  #      tmp_path, and sun_path is 108 bytes. The new root is only +3 bytes
  #      (54 vs 51, leaving 54 for the test subdir and socket name), but it
  #      wants to run the socket and seed-case tests under it after batch D.
  #   2. home.sessionVariables reaches LOGIN shells only, so this is inert for
  #      every session already running. It must not be mistaken for a fix that
  #      took effect on rebuild.
  #
  # /mnt/bulk/pytest-tmp must stay HAND-MADE on the mounted volume. Never add a
  # tmpfiles.d rule or an activation `mkdir -p` for it: /mnt/bulk is `nofail`,
  # so if the mount were absent such a rule would create the directory on `/`
  # under the empty mountpoint and silently restore this exact leak, hidden
  # under the mount when it returned. With no rule, a missing mount fails loudly
  # at session start, which is the behaviour we want.
  #
  # home.sessionVariables.PYTEST_DEBUG_TEMPROOT = "/mnt/bulk/pytest-tmp";
}
