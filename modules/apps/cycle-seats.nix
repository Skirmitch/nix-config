{ config, lib, pkgs, ... }:
let
  cfg = config.cycle;
  inherit (lib) mkOption mkIf types mapAttrs' mapAttrsToList nameValuePair
                concatStringsSep concatMapStringsSep attrNames optionalString;

  seats = cfg.seats;
  seatNames = attrNames seats;

  dbUrl = s: "postgres://${s.dbRole}@/${s.dbRole}?host=/run/postgresql";
  redisUrl = s: "redis://127.0.0.1:${toString s.redisPort}/0";
  scratchOf = n: "${cfg.scratchRoot}/${n}";

  # /etc/cycle/seats.json — a CROSS-CHECK, not a source.
  #
  # Builder's design, and the distinction matters: `bt` derives its scratch root the way
  # the harness does, then compares it against this table and refuses loudly when they
  # disagree. That disagreement is exactly what a plain `claude --continue` looks like
  # (base /tmp vs the table's /mnt/scratch/builder), so a bypass announces itself instead
  # of silently landing bytes back on the OS disk.
  seatsJson = pkgs.writeText "seats.json" (builtins.toJSON {
    version = 1;
    scratchRoot = cfg.scratchRoot;
    seats = mapAttrs' (n: s: nameValuePair n {
      inherit (s) folder dbRole redisPort memoryMax memorySwapMax;
      scratch = scratchOf n;
      quota = s.scratchQuota;
      alarm = s.scratchAlarm;
      databaseUrl = dbUrl s;
      redisUrl = redisUrl s;
    }) seats;
  });

  seatCase = concatMapStringsSep "\n" (n: ''    ${n}) : ;;'') seatNames;

  seatLauncher = pkgs.writeShellApplication {
    name = "seat";
    runtimeInputs = [ pkgs.systemd pkgs.coreutils pkgs.jq ];
    text = ''
      set -euo pipefail
      SEATS="${concatStringsSep " " seatNames}"
      name="''${1:-}"
      if [ -z "$name" ]; then
        echo "usage: seat <name> [claude args...]" >&2
        echo "seats: $SEATS" >&2
        exit 2
      fi
      shift
      case " $SEATS " in *" $name "*) ;; *)
        echo "seat: unknown seat '$name' (have: $SEATS)" >&2; exit 2 ;;
      esac

      J=/etc/cycle/seats.json
      [ -r "$J" ] || { echo "seat: $J missing" >&2; exit 1; }
      folder=$(jq -r --arg n "$name" '.seats[$n].folder'      "$J")
      dburl=$( jq -r --arg n "$name" '.seats[$n].databaseUrl' "$J")
      rdurl=$( jq -r --arg n "$name" '.seats[$n].redisUrl'    "$J")
      scratch=$(jq -r --arg n "$name" '.seats[$n].scratch'    "$J")

      # FAIL CLOSED.
      #
      # The first draft of this printed a warning and launched anyway when the scratch
      # root was missing. That is the worst possible behaviour: /mnt is root-owned so
      # `mkdir -p` fails, TMPDIR stays unset, and every byte lands back on the OS disk -
      # silently, which is the exact failure this whole module exists to end. A hostile
      # review found it independently. If the bound is not there, do not run.
      if [ ! -d "$scratch" ] || [ ! -w "$scratch" ]; then
        echo "seat: REFUSING - $scratch is missing or not writable." >&2
        echo "seat: the disk quota is the only thing that enforces the scratch bound," >&2
        echo "seat: so launching without it would put the bytes back on the OS disk." >&2
        echo "seat: check that /mnt/scratch is mounted (it is nofail, so it can be absent)." >&2
        exit 1
      fi

      cd "$HOME/$folder"

      # XDG_RUNTIME_DIR IS DELIBERATELY INHERITED, NEVER CLEARED.
      #
      # The cross-session socket dir is `XDG_RUNTIME_DIR || CLAUDE_CODE_TMPDIR ||
      # os.tmpdir()` + /cc-socks (Builder, read from the 2.1.282 binary). Sanitise the
      # environment and each seat's socket moves under its OWN per-seat temp dir, and the
      # seats stop seeing each other in ListAgents. Verified: `systemd-run --user --scope`
      # preserves it. Never `env -i` here.
      #
      # BOTH temp variables are set, and that is not redundant:
      #   CLAUDE_CODE_TMPDIR moves the HARNESS's own scratchpad;
      #   TMPDIR moves the TOOLS' mkdtemp worlds.
      # Operator leaked 99 directories into /tmp in one suite run - those were the second
      # kind. The quota only bounds what lands inside it.
      #
      # BT_SCRATCH_ROOT is deliberately NOT set. Builder: "it is a fixture seam."
      # `bt scratch` derives its root the way the harness does, so moving TMPDIR moves the
      # sweep with it. Setting it would have silently disarmed the only automated sweep on
      # this machine, because its basename guard rejects any root not named after the seat
      # and the callers swallowed the refusal.
      # DEFAULT TO --continue.
      #
      # A seat IS its accumulated context; a fresh session is not the same seat wearing
      # the same name. The first version ran bare `claude`, so `seat builder` silently
      # started over and threw the session away. Flags still pass straight through, so
      # `seat operator --resume <id>`, `--model ...` and anything added later all work;
      # only the no-argument case is opinionated.
      if [ "$#" -eq 0 ]; then
        args=(--continue)
      else
        args=("$@")
      fi

      exec systemd-run --user --scope --quiet \
        --unit="cycle-$name-$$" \
        --slice="cycle-$name.slice" \
        -p OOMPolicy=continue \
        --setenv=CYCLE_SEAT="$name" \
        --setenv=CLAUDE_CODE_TMPDIR="$scratch" \
        --setenv=TMPDIR="$scratch" \
        --setenv=DATABASE_URL="$dburl" \
        --setenv=REDIS_URL="$rdurl" \
        -- claude "''${args[@]}"
    '';
  };

  # SessionStart hook: reports a broken launch, and stamps the owner file the sweep needs.
  sessionHook = pkgs.writeShellApplication {
    name = "cycle-session-start";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.systemd pkgs.gnugrep ];
    text = ''
      set -uo pipefail
      J=/etc/cycle/seats.json
      bad=0
      MSG=""

      # OUTPUT CHANNEL: JSON on stdout, exit 0. NOT stderr.
      #
      # Measured: a SessionStart hook's stderr is shown ONLY on exit 2, and exit 2 cannot
      # block a session anyway - so the first version of this wrote to stderr and was
      # invisible. It fired correctly on every launch and nobody ever saw it.
      #
      # hookSpecificOutput gives two channels and we want both:
      #   systemMessage    -> JL sees it in the terminal
      #   additionalContext-> the SEAT reads it, which is what lets a seat refuse to work
      #                       unbounded instead of needing to check for itself.
      # additionalContext is only emitted when something is WRONG, so a healthy launch
      # costs one line of terminal and zero context tokens.
      say() { MSG="''${MSG}cycle: $*"$'\n'; }

      # SCOPE FIRST, AND SILENTLY.
      #
      # This hook is registered GLOBALLY, so it runs for every Claude session on the box -
      # the nix-config session, coach, archivist, anything started in a random directory.
      # None of those are seats and none of them should be told to "use `seat <name>`".
      # So the question is never "is CYCLE_SEAT set" (that would scold every ordinary
      # session); it is "am I standing in a seat's folder". Anywhere else: say nothing,
      # exit 0, cost one jq.
      [ -r "$J" ] || exit 0

      here=""
      for n in $(jq -r '.seats | keys[]' "$J" 2>/dev/null); do
        f=$(jq -r --arg n "$n" '.seats[$n].folder' "$J")
        case "$PWD" in "$HOME/$f"|"$HOME/$f"/*) here="$n"; break ;; esac
      done
      [ -n "$here" ] || exit 0          # not a seat folder: this hook has no opinion

      seat="''${CYCLE_SEAT:-}"
      if [ -z "$seat" ]; then
        say "################################################################"
        say "THIS IS THE $here SEAT, BUT IT WAS NOT LAUNCHED VIA \`seat\`."
        say "No slice, no memory ceiling, no scratch quota, no per-seat DB/Redis."
        say "Scratch will land on the OS disk. Restart with:  seat $here"
        say "################################################################"
        jq -n --arg m "$MSG" --arg c "This is the $here seat but it was NOT launched via \`seat\`. It has no memory ceiling, no scratch quota, and no per-seat database or Redis; its scratch will land on the OS disk. Tell the user and suggest relaunching with: seat $here" \
          '{hookSpecificOutput:{hookEventName:"SessionStart",systemMessage:$m,additionalContext:$c}}'
        exit 0
      fi

      # the cwd must be the folder the table maps this seat to
      want=$(jq -r --arg n "$seat" '.seats[$n].folder' "$J")
      case "$PWD" in "$HOME/$want"|"$HOME/$want"/*) ;; *)
        say "FAIL CYCLE_SEAT=$seat but cwd is $PWD, expected \$HOME/$want"; bad=1 ;;
      esac

      grep -q "cycle-$seat.slice" /proc/self/cgroup 2>/dev/null \
        || { say "FAIL not in cycle-$seat.slice - memory limits do NOT apply"; bad=1; }

      scratch=$(jq -r --arg n "$seat" '.seats[$n].scratch' "$J")
      case "''${TMPDIR:-}" in "$scratch"*) ;; *)
        say "FAIL TMPDIR=''${TMPDIR:-<unset>} is not under $scratch - the quota does not cover it"; bad=1 ;;
      esac

      # A launcher that sanitised the environment would move the socket under the seat's
      # own temp dir, and the seats would silently stop seeing each other.
      case "''${CLAUDE_CODE_MESSAGING_SOCKET:-}" in
        /run/user/*/cc-socks/*) ;;
        "") say "WARN CLAUDE_CODE_MESSAGING_SOCKET unset" ;;
        *) say "FAIL socket at ''${CLAUDE_CODE_MESSAGING_SOCKET} is outside /run/user/*/cc-socks - cross-session messaging is broken"; bad=1 ;;
      esac

      # OWNER FILE for the sweep.
      #
      # {boot_id, pid, starttime}, not {pid, starttime}: pids restart low every boot and
      # starttime is ticks-since-boot, so the pair collides across boots. A differing
      # boot_id means dead, full stop. pid comes from CLAUDE_PID because this hook's own
      # parent may be a shell. Rewritten on EVERY start including resume, because the
      # scratchpad directory outlives the process under --continue.
      # THE SESSION ID ARRIVES ON STDIN, NOT IN THE ENVIRONMENT.
      #
      # Builder proved this by dogfooding: it relaunched via `seat`, and afterwards NONE
      # of the session dirs under its scratch root held a .cycle-owner - while the script
      # still cheerfully printed "ok". Running it by hand with CLAUDE_CODE_SESSION_ID and
      # CLAUDE_PID stripped reproduced it exactly. Hooks are fed a JSON object on stdin
      # (session_id, cwd, hook_event_name, source); the env vars a Bash TOOL sees are not
      # the env a HOOK sees.
      sid=$(jq -r '.session_id // empty' 2>/dev/null <&0 || true)
      [ -n "$sid" ] || sid="''${CLAUDE_CODE_SESSION_ID:-}"

      # AND NEVER FALL BACK TO $PPID. This was a data-loss bug, not a cosmetic one.
      # If the harness runs the hook through a short-lived shell, $PPID dies immediately,
      # the owner file records a dead pid, and the reaper then deletes a LIVE session's
      # scratchpad. Walk up for the actual claude process instead, and if there is no
      # claude ancestor, write NOTHING and fail loudly - a missing owner file is handled
      # safely by the reaper's age fallback; a wrong one is not.
      cpid=""
      if [ -n "''${CLAUDE_PID:-}" ] && [ -d "/proc/''${CLAUDE_PID}" ]; then
        cpid="$CLAUDE_PID"
      else
        _p=$PPID; _n=0
        while [ "''${_p:-1}" -gt 1 ] && [ "$_n" -lt 12 ]; do
          case "$(cat "/proc/$_p/comm" 2>/dev/null)" in
            .claude-unwrapp|claude) cpid="$_p"; break ;;
          esac
          _p=$(awk '{print $4}' "/proc/$_p/stat" 2>/dev/null)
          _n=$((_n+1))
        done
      fi
      # Derive the path from the REAL temp base, not from the table.
      #
      # Using the table's value stamped an owner file into the bulk disk even when the
      # session's actual scratchpad was on /tmp - a phantom directory mapping to nothing,
      # which also polluted the sweep's view of what is alive. The harness builds its base
      # as CLAUDE_CODE_TMPDIR || os.tmpdir() (which reads TMPDIR), so mirror that exactly
      # and the owner file always lands beside the scratchpad it describes.
      base="''${CLAUDE_CODE_TMPDIR:-''${TMPDIR:-/tmp}}"
      # The "ok" line must not claim a check it never made. Before this, it printed ok
      # whether or not the owner file was written, which is precisely how the missing
      # owner files went unnoticed.
      if [ -z "$sid" ]; then
        say "FAIL no session id (not on stdin, not in env) - no owner file written"; bad=1
      elif [ -z "$cpid" ]; then
        say "FAIL no claude ancestor found - refusing to write an owner file with a wrong pid"; bad=1
      else
        slug=$(echo "$PWD" | tr '/' '-')
        d="$base/claude-$(id -u)/$slug/$sid"
        st=$(awk '{print $22}' "/proc/$cpid/stat" 2>/dev/null || echo "")
        if [ -n "$st" ] && mkdir -p "$d" 2>/dev/null && \
           printf '{"boot_id":"%s","pid":%s,"starttime":%s,"seat":"%s"}\n' \
             "$(cat /proc/sys/kernel/random/boot_id)" "$cpid" "$st" "$seat" > "$d/.cycle-owner"; then
          :
        else
          say "FAIL could not write the owner file at $d - the sweep cannot see this session"; bad=1
        fi
      fi

      if [ "$bad" = 0 ]; then
        jq -n --arg m "cycle: seat $seat ok (slice, quota, scratch, socket)" \
          '{hookSpecificOutput:{hookEventName:"SessionStart",systemMessage:$m}}'
      else
        ctx="This seat is running OUTSIDE its isolation. Specifically:
''${MSG}
That means no memory ceiling, no scratch quota, and possibly the wrong database or
Redis. Scratch will land on the OS disk, which is the failure that nearly filled root
on 2026-09-26. Tell the user, and do not start heavy or long-running work until it is
relaunched with: seat $seat"
        jq -n --arg m "''${MSG}cycle: ^^^ LAUNCH IS DEGRADED" --arg c "$ctx" \
          '{hookSpecificOutput:{hookEventName:"SessionStart",systemMessage:$m,additionalContext:$c}}'
      fi
      exit 0
    '';
  };

  # The sweep. Seat-neutral, so Operator gets one for the first time.
  sweeper = pkgs.writeShellApplication {
    name = "cycle-scratch-sweep";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.findutils pkgs.gawk ];
    text = ''
      set -uo pipefail
      J=/etc/cycle/seats.json
      [ -r "$J" ] || exit 0
      BOOT=$(cat /proc/sys/kernel/random/boot_id)
      DRY="''${CYCLE_SWEEP_DRY:-0}"

      # PREFLIGHT. This sweep deletes directories, so a missing dependency must stop it
      # rather than silently change what it decides. See the awk incident above.
      for _t in jq find date; do
        command -v "$_t" >/dev/null 2>&1 || {
          echo "REFUSING to sweep: $_t is not on PATH; a missing tool must not be read as 'dead'"
          exit 1
        }
      done

      # QUOTA ESCAPE DETECTOR.
      #
      # MEASURED 2026-09-26, and it is a real hole: an unprivileged user can run
      # `btrfs subvolume create` inside their own quota'd scratch subvolume, and the new
      # subvolume gets its OWN qgroup with no limit. Writing 36 GB past a 32 GB limit
      # succeeded with no error. Plain directories ARE counted; only a nested subvolume
      # escapes. Worse, a NON-EMPTY escaped subvolume cannot be removed without root
      # (user_subvol_rm_allowed is absent from every mount), so it is also a cleanup trap.
      #
      # This cannot be PREVENTED from here - write access to a directory on btrfs implies
      # the ability to create a subvolume in it, and the seats need write access. So it is
      # detected and reported loudly instead. Two things bound the damage meanwhile:
      # nothing in either seat's tooling creates subvolumes in scratch today, and an
      # escape fills the BULK disk, never the OS disk, so the machine stays up.
      #
      # The permanent fix, if this ever bites: put scratch on a filesystem with no
      # subvolumes at all - XFS or ext4 with project quotas, which inherit into
      # subdirectories and cannot be escaped this way.
      for seat in $(jq -r '.seats | keys[]' "$J"); do
        root=$(jq -r --arg n "$seat" '.seats[$n].scratch' "$J")
        [ -d "$root" ] || continue
        # subvolume roots are always inode 256; the seat root itself is expected
        find "$root" -mindepth 1 -xdev -inum 256 -type d 2>/dev/null | while IFS= read -r sv; do
          echo "ESCAPE: $sv is a nested subvolume inside $seat's quota'd scratch."
          echo "        It has its OWN qgroup and is NOT bound by the ''${seat} limit."
          echo "        Size: $(du -sh "$sv" 2>/dev/null | cut -f1). Removing it needs root."
        done
      done

      for seat in $(jq -r '.seats | keys[]' "$J"); do
        root=$(jq -r --arg n "$seat" '.seats[$n].scratch' "$J")
        [ -d "$root" ] || continue
        find "$root" -mindepth 3 -maxdepth 3 -type d -name '*-*-*-*-*' 2>/dev/null |
        while IFS= read -r d; do
          own="$d/.cycle-owner"
          if [ -f "$own" ]; then
            ob=$(jq -r '.boot_id' "$own" 2>/dev/null || echo "")
            op=$(jq -r '.pid'     "$own" 2>/dev/null || echo "")
            os=$(jq -r '.starttime' "$own" 2>/dev/null || echo "")
            # Different boot = the owner is dead, no further test needed.
            if [ "$ob" != "$BOOT" ]; then
              echo "dead (old boot): $d"
              [ "$DRY" = 1 ] || rm -rf -- "$d"
              continue
            fi
            # FAIL CLOSED: an unreadable probe means ALIVE, never dead.
            #
            # This deleted a LIVE session on 2026-09-26 at 22:00:07. The cause was
            # `awk` - coreutils does NOT provide it and it was not in runtimeInputs, so
            # inside the service it was command-not-found, my own 2>/dev/null swallowed
            # the error, the variable came back empty, and EMPTY MEANT DELETE. It passed
            # every test because an interactive shell has awk on PATH and the service
            # does not. A missing binary must never be indistinguishable from a dead pid.
            #
            # Now parsed in pure bash with no external command at all. /proc/PID/stat is
            # "pid (comm) state ..." and comm may contain spaces and parens, so strip
            # through the LAST ") " before splitting; starttime is then field 20.
            now=""
            if [ -r "/proc/$op/stat" ]; then
              statline=$(< "/proc/$op/stat") || statline=""
              if [ -n "$statline" ]; then
                rest=''${statline##*') '}
                # shellcheck disable=SC2086
                set -- $rest
                now=''${20:-}
              fi
            fi

            if [ ! -e "/proc/$op" ]; then
              echo "dead (no such pid): $d"
              [ "$DRY" = 1 ] || rm -rf -- "$d"
            elif [ -z "$now" ]; then
              echo "KEEPING $d - the pid exists but its starttime could not be read."
              echo "        Refusing to delete on an unreadable probe."
            elif [ "$now" != "$os" ]; then
              echo "dead (pid reused, starttime $now != $os): $d"
              [ "$DRY" = 1 ] || rm -rf -- "$d"
            fi
          else
            # No owner file is exactly what a PLAIN launch produces, and a plain-launched
            # session may be alive right now. Builder's amendment: the fallback window
            # must be long. An hour would reap live seats that started the old way.
            # ABSOLUTE timestamp, deliberately, not `-newermt '-2 days'`.
            #
            # Relative timestamps are a GNU-find extension. bfs - which is what `find`
            # resolves to in an interactive shell on this box - REJECTS them outright
            # ("Invalid timestamp, supported formats are ISO 8601-like"). Under bfs the
            # test returns empty, which falls straight through to the DELETE branch: the
            # reaper would remove every live scratchpad that has no owner file. It is
            # correct today only because writeShellApplication puts GNU findutils on this
            # script's own PATH, which is one refactor away from not being true.
            cutoff=$(date -d '2 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)
            if [ -z "$cutoff" ]; then
              echo "REFUSING to sweep: cannot compute the cutoff date"; exit 1
            fi
            if [ -n "$(find "$d" -newermt "$cutoff" -print -quit 2>/dev/null)" ]; then
              : # touched recently, leave it
            else
              echo "unowned and cold >2d: $d"
              [ "$DRY" = 1 ] || rm -rf -- "$d"
            fi
          fi
        done
      done
    '';
  };
in
{
  options.cycle = {
    scratchRoot = mkOption {
      type = types.str;
      default = "/mnt/scratch";
      description = "Parent of the per-seat scratch subvolumes, on the bulk disk.";
    };
    seats = mkOption {
      default = { };
      description = ''
        The cycle-hq seats. One source of truth: postgres roles, the drop-timer exemption,
        redis instances, systemd slices, the launcher, the SessionStart hook, the sweep
        and /etc/cycle/seats.json all derive from here.

        Both seats independently asked for a TABLE rather than an alternation, and the
        proof it matters is already in the tree: the exemption regex shipped as
        `(_operator|_builder)` would have silently dropped a third seat's test databases
        nightly, and the Constructor and Seba folders already exist.
      '';
      type = types.attrsOf (types.submodule {
        options = {
          folder = mkOption { type = types.str; description = "Seat dir relative to \$HOME."; };
          dbRole = mkOption { type = types.str; description = "Postgres role and database name."; };
          redisPort = mkOption { type = types.port; description = "This seat's own redis instance."; };
          scratchQuota = mkOption { type = types.str; description = "btrfs qgroup limit (informational here; set with `btrfs qgroup limit`)."; };
          scratchAlarm = mkOption { type = types.str; description = "Warn at this usage, so the wall is never the first signal."; };
          memoryHigh = mkOption { type = types.str; default = ""; description = "Throttle. Empty until Phase 4 tunes it from memory.stat anon."; };
          memoryMax = mkOption { type = types.str; description = "Hard RAM ceiling."; };
          memorySwapMax = mkOption { type = types.str; description = "Hard SWAP ceiling. MemoryMax alone is NOT a bound: swap defaults to max with 93 GiB to grow into, which is the 2026-09-22 unclean reset."; };
          cpuWeight = mkOption { type = types.int; default = 100; description = "Relative CPU share. Weight, never quota."; };
        };
      });
    };
  };

  config = mkIf (seats != { }) {
    environment.etc."cycle/seats.json".source = seatsJson;
    environment.systemPackages = [ seatLauncher sweeper ];

    # One redis instance per seat. Builder measured why an index will not do: with
    # REDIS_URL=<host>/1 the repo's own test_celery_settings_default_to_single_db_with_
    # prefix_separation FAILS, because the broker is built as <host>/0 and pinned equal to
    # the cache. A different HOST at /0 passes.
    services.redis.servers = mapAttrs' (n: s: nameValuePair n {
      enable = true;
      bind = "127.0.0.1";
      port = s.redisPort;
      save = [ ];
    }) seats;

    systemd.user.slices =
      (mapAttrs' (n: s: nameValuePair "cycle-${n}" {
        description = "cycle-hq seat: ${n}";
        sliceConfig = {
          MemoryAccounting = true;
          TasksAccounting = true;
          MemoryMax = s.memoryMax;
          MemorySwapMax = s.memorySwapMax;
          CPUWeight = s.cpuWeight;
        } // lib.optionalAttrs (s.memoryHigh != "") { MemoryHigh = s.memoryHigh; };
      }) seats)
      // {
        # The parent budget: what makes this survive a third seat. Per-seat ceilings are
        # ceilings, not a partition - three seats at 32G is 96G on a 61 GiB box.
        cycle = {
          description = "cycle-hq seats (parent budget)";
          sliceConfig = {
            MemoryAccounting = true;
            TasksAccounting = true;
            MemoryMax = cfg.parentMemoryMax or "44G";
            MemorySwapMax = "16G";
          };
        };
      };

    systemd.user.services.cycle-scratch-sweep = {
      description = "Reap scratch directories whose owning session is dead";
      serviceConfig = { Type = "oneshot"; ExecStart = "${sweeper}/bin/cycle-scratch-sweep"; };
    };
    systemd.user.timers.cycle-scratch-sweep = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "hourly"; Persistent = true; };
    };

    environment.etc."cycle/session-start".source = "${sessionHook}/bin/cycle-session-start";
  };
}
