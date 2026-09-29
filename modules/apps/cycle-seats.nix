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
      readOnly = s.readOnlyPaths;
      quota = s.scratchQuota;
      alarm = s.scratchAlarm;
      databaseUrl = dbUrl s;
      redisUrl = redisUrl s;
    }) seats;
  });

  seatCase = concatMapStringsSep "\n" (n: ''    ${n}) : ;;'') seatNames;

  seatLauncher = pkgs.writeShellApplication {
    name = "seat";
    runtimeInputs = [ pkgs.systemd pkgs.coreutils pkgs.jq pkgs.bubblewrap ];
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

      # READ-ONLY PATHS, enforced by the kernel rather than by reading command text.
      #
      # bwrap is used rather than systemd's ReadOnlyPaths= because a systemd SCOPE
      # rejects sandboxing properties outright - measured: "Unknown assignment:
      # ReadOnlyPaths=". Scopes adopt a process the caller already started, so there is
      # no namespace for systemd to apply them in, and the launcher uses a scope
      # deliberately: it is what keeps the terminal attached.
      #
      # `--dev-bind / /` passes the whole filesystem through UNCHANGED and writable; the
      # ro-binds are the only difference. Measured 2026-09-29 inside such a namespace:
      # cc-socks reachable (so the seats still see each other), scratch writable,
      # ~/.claude writable, the postgres socket reachable, /proc intact.
      wrap=()
      ro=$(jq -r --arg n "$name" '.seats[$n].readOnly[]?' "$J" 2>/dev/null || true)
      if [ -n "$ro" ]; then
        # FAIL CLOSED. If a seat is declared read-only somewhere and the tool that
        # enforces it is missing, launching anyway would hand it write access while
        # everyone believes otherwise - the worst of both, and silent.
        command -v bwrap >/dev/null 2>&1 || {
          echo "seat: $name declares read-only paths but bwrap is not on PATH." >&2
          echo "      Refusing to launch WITHOUT the protection everyone thinks is on." >&2
          exit 1
        }
        wrap=(bwrap --dev-bind / /)
        while IFS= read -r rp; do
          [ -n "$rp" ] || continue
          # bwrap dies cryptically on a missing source; say which path and why.
          [ -e "$rp" ] || {
            echo "seat: read-only path $rp does not exist; refusing to launch." >&2
            exit 1
          }
          wrap+=(--ro-bind "$rp" "$rp")
        done <<< "$ro"
        wrap+=(--)
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
        -- "''${wrap[@]}" claude "''${args[@]}"
    '';
  };

  # SessionStart hook: reports a broken launch, and stamps the owner file the sweep needs.
  sessionHook = pkgs.writeShellApplication {
    name = "cycle-session-start";
    # btrfs-progs and util-linux let the hook VERIFY the quota instead of asserting it
    # (C7-H1 below). Both of those reads are unprivileged.
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.systemd pkgs.gnugrep pkgs.btrfs-progs pkgs.util-linux ];
    text = ''
      set -uo pipefail
      # CYCLE_SEATS_JSON is a TEST SEAM matching the sweep's. Builder could not exercise
      # the no-limit branch without one: he cannot remove a qgroup limit, but he CAN make
      # a fresh unlimited subvolume inside his own scratch and point a fixture table at
      # it. The override ANNOUNCES itself below, so a message produced against a fake
      # table can never be mistaken for a real check - which is the exact failure this
      # hook was just repaired for.
      J="''${CYCLE_SEATS_JSON:-/etc/cycle/seats.json}"
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

      if [ -n "''${CYCLE_SEATS_JSON:-}" ]; then
        say "NOTE using the table at $J via CYCLE_SEATS_JSON - this is a TEST run"
      fi

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

      # C7-H1: VERIFY THE QUOTA, DO NOT CLAIM IT.
      #
      # Operator's finding. The healthy line read "ok (slice, quota, scratch, socket)"
      # while testing no quota whatsoever. The qgroups existed only because somebody had
      # set them by hand with root, so a seat added later would have got an unbounded
      # plain directory and this line would STILL have said "ok". A message asserting a
      # check it never makes is worse than no message: it turns the ABSENCE of a bound
      # into positive evidence of one.
      #
      # Builder made the honest version cheap by withdrawing his own earlier claim that
      # these need root: /sys/fs/btrfs/<uuid>/qgroups/0_<rootid>/ reads fine unprivileged,
      # and so does `btrfs inspect-internal rootid`. So read the limit ACTUALLY IN FORCE
      # and compare it against the table.
      quota_line=""
      if ! command -v btrfs >/dev/null 2>&1 || ! command -v findmnt >/dev/null 2>&1; then
        say "WARN btrfs/findmnt missing - the scratch quota is UNVERIFIED, not confirmed"
      else
        qwant=$(jq -r --arg n "$seat" '.seats[$n].quota' "$J" 2>/dev/null)
        qalarm=$(jq -r --arg n "$seat" '.seats[$n].alarm' "$J" 2>/dev/null)
        rid=$(btrfs inspect-internal rootid "$scratch" 2>/dev/null) || rid=""
        fsu=$(findmnt -no UUID -T "$scratch" 2>/dev/null) || fsu=""  # -T: a PATH, not a mountpoint
        if [ -z "$rid" ] || [ -z "$fsu" ]; then
          say "WARN could not identify the scratch subvolume - quota UNVERIFIED"
        else
          qd="/sys/fs/btrfs/$fsu/qgroups/0_$rid"
          maxr=$(cat "$qd/max_referenced" 2>/dev/null) || maxr=""
          usedr=$(cat "$qd/referenced" 2>/dev/null) || usedr=""
          if [ -z "$maxr" ] || [ "$maxr" = "0" ]; then
            say "FAIL $scratch has NO qgroup limit in force. The table says $qwant."
            say "     Scratch is UNBOUNDED. Fix: sudo systemctl restart cycle-scratch-quota"
            bad=1
          elif [ -z "$usedr" ]; then
            say "WARN the qgroup limit is set but usage is unreadable - alarm UNVERIFIED"
          else
            # C4-H1: the alarm had nowhere to go. It goes here. Pure bash arithmetic,
            # because awk is NOT in this hook's runtimeInputs and assuming that it was is
            # precisely the bug that deleted a live session on 2026-09-26.
            # Round to the nearest tenth, do not floor. Builder measured 101 MB printing
            # as 0.0; the same floor would read 9.9 for 9.99 directly beside an alarm
            # threshold, which is the one place a number must not flatter itself.
            t=$(( (usedr * 10 + 536870912) / 1073741824 ))
            quota_line=", quota $(( t / 10 )).$(( t % 10 ))/$(( maxr / 1073741824 )) GiB"
            ab=$(numfmt --from=iec "$qalarm" 2>/dev/null) || ab=0
            if [ "''${ab:-0}" -gt 0 ] && [ "$usedr" -ge "$ab" ] 2>/dev/null; then
              say "WARN scratch is at $(( t / 10 )).$(( t % 10 )) GiB, past the $qalarm alarm (wall $qwant)."
              say "     The wall must never be the first signal. Collect your garbage now."
            fi
          fi
        fi
      fi

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
          # ppid WITHOUT awk - gawk is not in this hook's runtimeInputs, so this resolved
          # only through the caller's ambient PATH, and the 2>/dev/null swallowed the
          # command-not-found. In a service _p came back EMPTY, the ancestor walk ended,
          # and the hook reported "no claude ancestor found" and wrote no owner file at
          # all. Third instance of the awk bug in this module; the last one cost a live
          # session. Raw stat is "pid (comm) state ppid ...", so after stripping through
          # the LAST ") " the ppid is field 2 of the remainder.
          _st=""
          if [ -r "/proc/$_p/stat" ]; then
            _st=$(< "/proc/$_p/stat") || _st=""
          fi
          if [ -n "$_st" ]; then
            _rest=''${_st##*') '}
            # shellcheck disable=SC2086
            set -- $_rest
            _p=''${2:-}
          else
            _p=""
          fi
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
        # FIND the scratchpad; do not RECONSTRUCT it.
        #
        # The old line derived it as `echo "$PWD" | tr '/' '-'`, wrong twice. First, the
        # harness keys the slug on the LAUNCH directory, while $PWD is wherever the shell
        # happens to be when the hook fires - a compaction with the shell cd'd into a
        # subdirectory stamped an owner into a PHANTOM session directory (Builder,
        # 2026-09-27), which then showed up in the sweep as a dead session. Second, the
        # harness collapses every run of [^A-Za-z0-9] to '-', while tr '/' '-' keeps dots
        # and underscores, so the two disagree on any path containing either.
        #
        # Rather than re-implement a rule that can drift, look for the directory the
        # harness already created. The session id is unique, so one glob over the slug
        # level finds it without needing to know the rule at all.
        uid=$(id -u)
        d=""
        for cand in "$base/claude-$uid"/*/"$sid"; do
          [ -d "$cand" ] || continue
          d="$cand"; break
        done
        if [ -z "$d" ]; then
          slug=$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9][^A-Za-z0-9]*/-/g')
          d="$base/claude-$uid/$slug/$sid"
        fi

        # starttime WITHOUT awk. gawk is NOT in this hook's runtimeInputs (coreutils, jq,
        # systemd, gnugrep - verified in the generated script's PATH), so `awk` here
        # resolved only through the CALLER's ambient PATH: present in an interactive
        # shell, absent in a service. That is byte-for-byte the failure that deleted a
        # live session on 2026-09-26, sitting unnoticed in the hook. Parsed in pure bash
        # now: /proc/PID/stat is "pid (comm) state ...", comm may contain spaces and
        # parens, so strip through the LAST ") " and take field 20 of the remainder -
        # the same parse the sweep uses, which is also why they agree.
        st=""
        if [ -r "/proc/$cpid/stat" ]; then
          statline=$(< "/proc/$cpid/stat") || statline=""
          if [ -n "$statline" ]; then
            rest=''${statline##*') '}
            # shellcheck disable=SC2086
            set -- $rest
            st=''${20:-}
          fi
        fi

        # ATOMIC WRITE. The old form redirected straight onto .cycle-owner, so the shell
        # TRUNCATED the file before printf ran: a write that failed - notably EDQUOT once
        # the seat's quota is full - left a 0-byte owner behind, which the old sweep read
        # as "not this boot" and deleted outright. Fill your scratch, lose your session.
        # Write to a temp file, mv into place (atomic within one filesystem), and remove
        # the partial if any step fails.
        ok=0
        if [ -n "$st" ] && mkdir -p "$d" 2>/dev/null; then
          tmp="$d/.cycle-owner.$$"
          if printf '{"boot_id":"%s","pid":%s,"starttime":%s,"seat":"%s"}\n' \
               "$(cat /proc/sys/kernel/random/boot_id)" "$cpid" "$st" "$seat" > "$tmp" 2>/dev/null \
             && mv -f "$tmp" "$d/.cycle-owner" 2>/dev/null; then
            ok=1
          else
            rm -f "$tmp" 2>/dev/null || true
          fi
        fi
        if [ "$ok" = 0 ]; then
          # TRUTHFUL. The old message claimed "the sweep cannot see this session", which
          # was never true and is now doubly untrue: with no owner file the sweep treats
          # the directory as unowned and applies the 2-day window, so a live session is
          # SAFE for two days rather than invisible. What is actually lost is the fast,
          # precise liveness signal - which is worth saying accurately, because a message
          # that overstates the danger gets ignored at exactly the wrong moment.
          say "FAIL could not write the owner file at $d. The sweep will fall back to the"
          say "     unowned 2-day rule for this session instead of a precise liveness"
          say "     check. Most likely cause: this seat's scratch quota is full."
          bad=1
        fi
      fi

      if [ "$bad" = 0 ]; then
        # "quota" leaves this list unless the check above CONFIRMED one, in which case
        # quota_line carries the measured usage instead of the bare word.
        jq -n --arg m "cycle: seat $seat ok (slice, scratch, socket)''${quota_line}" \
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
      # errexit IS ON HERE, whatever this line suggests. writeShellApplication injects
      # `set -o errexit -o nounset -o pipefail` ABOVE this text, and `set -uo pipefail`
      # does not unset it. Reading the nix source tells you errexit is off; reading the
      # generated script in the store tells you it is on. Verified 2026-09-27. Every
      # command below must therefore either succeed or be explicitly tolerated.
      set -uo pipefail

      # OUTPUT CONTRACT. Every verdict line begins with ONE stable token:
      #   KEEP:  / REAP: / UNREADABLE: / ESCAPE: / REFUSE:
      # Builder's ask, from a real failure: their matrix parser knew only the old verdict
      # WORDING, so a correct "reap (...)" first scored as KEEP. Coupling a reader to
      # prose means any reword silently changes what it scores. The token is the API; the
      # rest of the line is for humans and may be reworded freely.

      # The table. CYCLE_SEATS_JSON is a TEST SEAM (Builder's ask) so the acceptance
      # matrix can point the sweep at a fixture tree. It refuses to run WET against an
      # overridden table: a test harness has no business deleting real scratch, and a
      # seam that can delete is a seam that will one day delete the wrong thing.
      J="''${CYCLE_SEATS_JSON:-/etc/cycle/seats.json}"
      [ -r "$J" ] || exit 0
      BOOT=$(cat /proc/sys/kernel/random/boot_id)
      DRY="''${CYCLE_SWEEP_DRY:-0}"
      UIDN=$(id -u)

      if [ -n "''${CYCLE_SEATS_JSON:-}" ] && [ "$DRY" != 1 ]; then
        echo "REFUSE: CYCLE_SEATS_JSON is set but CYCLE_SWEEP_DRY is not 1."
        echo "        The table override is a test seam and must never delete real data."
        exit 1
      fi

      # AN UNREADABLE DIRECTORY MUST NOT SILENCE THE SWEEP.
      #
      # MEASURED by Builder 2026-09-27, 3 runs of 3: ONE mode-000 directory anywhere in a
      # seat's scratch made this script exit 1 with ZERO output, for EVERY seat, dry and
      # wet alike. Not hypothetical - overlayfs makes its work/work directory mode 000,
      # and the #3 overlay trial keeps its upper inside the seat scratch. The two
      # unexplained silent exit-1 sweeps at 08:45 were exactly this.
      #
      # Mechanism: `find` exits 1 when it cannot read a directory, `2>/dev/null` hid the
      # message, pipefail carried the 1 out of the pipeline, and the injected errexit
      # aborted the script before a single line was printed. Silent and total.
      #
      # An unreadable path is MISSING INFORMATION. It is named and skipped; it never stops
      # the sweep and never contributes to a delete decision. Results go to a file rather
      # than a pipe so the read loop runs in THIS shell, not a subshell.
      SCAN_OUT=""
      scan() {
        local root="$1"; shift
        local err rc
        SCAN_OUT=$(mktemp) || { echo "REFUSE: mktemp failed"; exit 1; }
        err=$(mktemp)      || { echo "REFUSE: mktemp failed"; exit 1; }
        # errexit is ON (see the header). A PLAIN command returning non-zero aborts the
        # script right here, so `rc=$?` would never run and the helper written to TOLERATE
        # a 1 would be killed by that 1 - the trap this file's own header warns about,
        # walked into three lines later. Builder proved it in isolation and caught it in
        # the acceptance matrix: this exact shape gave exit 1 with ZERO output against
        # Operator's live mode-000 overlay work dirs. `|| rc=$?` is what exempts it.
        rc=0
        find "$root" "$@" >"$SCAN_OUT" 2>"$err" || rc=$?
        if [ -s "$err" ]; then
          echo "UNREADABLE: under $root - skipped; the sweep continues and still judges"
          echo "        everything it CAN read:"
          sed 's/^/          /' "$err"
        fi
        rm -f "$err"
        # 1 means "some path was unreadable" and is expected. Anything higher is not.
        if [ "$rc" -gt 1 ]; then
          echo "REFUSE: find exited $rc under $root - not a permission problem"
          rm -f "$SCAN_OUT"
          exit 1
        fi
      }

      # PREFLIGHT. This sweep deletes directories, so a missing dependency must stop it
      # rather than silently change what it decides. See the awk incident above.
      for _t in jq find date; do
        command -v "$_t" >/dev/null 2>&1 || {
          echo "REFUSE: $_t is not on PATH; a missing tool must not be read as 'dead'"
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
        scan "$root" -mindepth 1 -xdev -inum 256 -type d
        while IFS= read -r sv; do
          [ -n "$sv" ] || continue
          echo "ESCAPE: $sv is a nested subvolume inside $seat's quota'd scratch."
          echo "        It has its OWN qgroup and is NOT bound by the ''${seat} limit."
          echo "        Size: $(du -sh "$sv" 2>/dev/null | cut -f1). Removing it needs root."
        done < "$SCAN_OUT"
        rm -f "$SCAN_OUT"
      done

      for seat in $(jq -r '.seats | keys[]' "$J"); do
        root=$(jq -r --arg n "$seat" '.seats[$n].scratch' "$J")
        [ -d "$root" ] || continue
        scan "$root" -mindepth 3 -maxdepth 3 -type d -path "$root/claude-$UIDN/*/*"
        while IFS= read -r d; do
          [ -n "$d" ] || continue

          # STRUCTURAL MATCH, not a shape guess. The harness lays a session out as
          #   <base>/claude-<uid>/<cwd-slug>/<session-uuid>
          # The old filter was `-name '*-*-*-*-*'`: any directory with four hyphens at
          # that depth. It says nothing about the two levels above it and cheerfully
          # matches a slug-shaped directory. The -path above pins claude-<uid> and the
          # slug level; this pins the leaf to an actual UUID. Anything else is not a
          # session directory and is passed over in silence - it is not ours to judge.
          leaf=''${d##*/}
          case "$leaf" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
            *) continue ;;
          esac

          # The seats' acceptance fixtures live under cycle-fixture/. A WET run never
          # touches them, so a test tree can sit inside real scratch safely.
          case "$d" in
            */cycle-fixture/*) [ "$DRY" = 1 ] || continue ;;
          esac

          own="$d/.cycle-owner"
          ob=""; op=""; os=""
          if [ -f "$own" ]; then
            ob=$(jq -r '.boot_id   // empty' "$own" 2>/dev/null) || ob=""
            op=$(jq -r '.pid       // empty' "$own" 2>/dev/null) || op=""
            os=$(jq -r '.starttime // empty' "$own" 2>/dev/null) || os=""
          fi

          # A LIVE PID IS POSITIVE EVIDENCE; everything else here is absence of evidence.
          # Builder's matrix: "missing boot_id with a live pid" must KEEP. If the owner
          # names a pid that exists right now, that outranks anything we failed to parse.
          if [ -n "$op" ] && [ -e "/proc/$op" ] && [ -z "$ob" ]; then
            echo "KEEP: $d - owner is partly unreadable but names pid $op, which exists."
            continue
          fi

          # AN UNREADABLE OWNER IS NOT A DEATH CERTIFICATE.
          #
          # C6, Builder's falsification, confirmed against this file on 2026-09-27. The
          # old branch was:
          #     if [ "$ob" != "$BOOT" ]; then echo "dead (old boot)"; rm -rf -- "$d"; fi
          # with NO age test - and an empty or torn owner file yields ob="", which is
          # also != BOOT. So a 0-BYTE OWNER MEANT IMMEDIATE RECURSIVE DELETE of a session
          # that may be alive.
          #
          # That is not a corner case, it is a composite failure. The hook writes the
          # owner non-atomically, so a write that fails on a full quota (EDQUOT) leaves
          # exactly the 0-byte file this branch read as "dead". Fill your scratch, lose
          # your session. Same shape as the awk incident: failing to LEARN something was
          # read as having learned "dead".
          #
          # An owner we cannot parse tells us NOTHING, so it falls back to the most
          # conservative window we have - the unowned 2-day one, never the 1-hour one.
          verdict=""; window=""; wlabel=""
          if [ -z "$ob" ] || [ -z "$op" ] || [ -z "$os" ]; then
            verdict="no readable owner"; window="2 days ago"; wlabel=">2d"
          elif [ "$ob" != "$BOOT" ]; then
            # C6-H3, Operator 2026-09-27, and it would have cost sessions.
            #
            # After a reboot EVERY resumable session has an owner from the previous boot,
            # and every one of them is cold, because the machine was off. Sessions come
            # back through `claude --continue`, which may be hours later - JL reboots at
            # night and resumes in the morning. So "the owner is from an older boot" is
            # not evidence of death at all; it is the ordinary state of a session waiting
            # to be resumed, and the 1-hour window I had here would have reaped the lot on
            # the first armed run after a boot.
            #
            # It gets the SAME long window as an unreadable owner, for the same reason:
            # we have learned nothing about whether this session is alive in THIS boot,
            # and absence of evidence must never shorten the fuse. Death-plus-age still
            # applies, so a genuinely abandoned directory still goes, just after two days
            # rather than one hour.
            verdict="owner recorded boot $ob, this boot is $BOOT"
            window="2 days ago"; wlabel=">2d"
          else
            # Same boot: probe the pid. Pure bash, no external command at all - see the
            # awk incident above. /proc/PID/stat is "pid (comm) state ..." and comm may
            # contain spaces and parens, so strip through the LAST ") " before splitting;
            # starttime is then field 20.
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
              verdict="no such pid"; window="1 hour ago"; wlabel=">1h"
            elif [ -z "$now" ]; then
              echo "KEEP: $d - the pid exists but its starttime could not be read."
              echo "        Refusing to delete on an unreadable probe."
              continue
            elif [ "$now" != "$os" ]; then
              verdict="pid reused, starttime $now != $os"
              window="1 hour ago"; wlabel=">1h"
            fi
          fi

          # Owner is alive and current. SAY SO, rather than passing over in silence.
          #
          # This used to `continue` with no output, making each run a PARTIAL account of
          # what it examined - and silence there is indistinguishable from "never looked".
          # That ambiguity is the shape of four defects found on 2026-09-27: an empty grep
          # reading as zero, a missing binary reading as dead, an unreadable owner reading
          # as a death certificate, and a find failure reading as nothing-to-do. One line
          # per live session per hour buys an output that accounts for everything it saw.
          if [ -z "$verdict" ]; then
            echo "KEEP: $d - owner pid $op is alive and from this boot."
            continue
          fi

          # DEATH PLUS AGE, IN EVERY BRANCH - this is the part C6 was missing. A live
          # session writes to its scratchpad constantly, so "untouched for a while" is an
          # INDEPENDENT signal. Requiring both means one wrong liveness verdict cannot by
          # itself destroy an active session, which is exactly what killed b7dbcc30.
          #
          # ABSOLUTE timestamp, deliberately. Relative -newermt is a GNU extension and
          # bfs - what `find` resolves to in an interactive shell here - rejects it, which
          # would return empty and fall through to DELETE.
          cutoff=$(date -d "$window" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)
          if [ -z "$cutoff" ]; then
            echo "REFUSE: cannot compute the '$window' cutoff"; exit 1
          fi
          if [ -n "$(find "$d" -newermt "$cutoff" -print -quit 2>/dev/null)" ]; then
            echo "KEEP: $d - $verdict, but it was written to within $wlabel."
            echo "        Two independent signals must agree before anything is removed."
          else
            echo "REAP: $d ($verdict, cold $wlabel)"
            [ "$DRY" = 1 ] || rm -rf -- "$d"
          fi
        done < "$SCAN_OUT"
        rm -f "$SCAN_OUT"
      done
    '';
  };
  # cycle-limits: what is ACTUALLY in force, and the one invariant a seat can break.
  #
  # The seats tune themselves with systemd drop-ins now, so the values in this repo are
  # defaults rather than truth. This reads the live cgroup settings and checks that the
  # per-seat MemoryMax figures still sum to less than the parent's - because exceeding it
  # is silent, and its consequence (the parent OOM picking a victim from the OTHER seat)
  # looks like an unrelated crash in someone else's session.
  limitsTool = pkgs.writeShellApplication {
    name = "cycle-limits";
    runtimeInputs = [ pkgs.systemd pkgs.coreutils pkgs.jq ];
    text = ''
      J="''${CYCLE_SEATS_JSON:-/etc/cycle/seats.json}"
      [ -r "$J" ] || { echo "cycle-limits: no readable $J"; exit 1; }

      g() { systemctl --user show "$1" -p "$2" --value 2>/dev/null || echo infinity; }
      h() { if [ "$1" = infinity ] || [ -z "$1" ]; then printf 'none'; else printf '%sG' "$(( $1 / 1073741824 ))"; fi; }

      pmax=$(g cycle.slice MemoryMax)
      pswap=$(g cycle.slice MemorySwapMax)
      ptask=$(g cycle.slice TasksMax)
      printf '%-24s %-10s %-10s %-10s %s\n' UNIT MemoryMax MemoryHigh SwapMax TasksMax
      printf '%-24s %-10s %-10s %-10s %s\n' cycle.slice "$(h "$pmax")" "$(h "$(g cycle.slice MemoryHigh)")" "$(h "$pswap")" "$ptask"

      sum=0; seats=0
      for n in $(jq -r '.seats | keys[]' "$J"); do
        u="cycle-$n.slice"
        m=$(g "$u" MemoryMax)
        printf '%-24s %-10s %-10s %-10s %s\n' "$u" "$(h "$m")" "$(h "$(g "$u" MemoryHigh)")" "$(h "$(g "$u" MemorySwapMax)")" "$(g "$u" TasksMax)"
        if [ "$m" != infinity ] && [ -n "$m" ]; then sum=$(( sum + m )); seats=$(( seats + 1 )); fi
      done

      echo
      if [ "$pmax" = infinity ]; then
        echo "WARN: cycle.slice has no MemoryMax. Nothing stops the seats taking the machine."
        exit 1
      fi
      printf 'seat MemoryMax total: %s across %s seat(s); parent: %s\n' "$(h "$sum")" "$seats" "$(h "$pmax")"
      if [ "$sum" -ge "$pmax" ]; then
        echo
        echo "FAIL: the seats can sum PAST the parent."
        echo "      The parent's OOM will fire before any seat reaches its own ceiling, and a"
        echo "      memcg OOM picks the worst task in the whole subtree - so one seat's"
        echo "      runaway can kill ANOTHER seat's session. Raise cycle.slice MemoryMax, or"
        echo "      lower a seat's, until the total is strictly below the parent."
        exit 1
      fi
      echo "OK: seat totals are strictly under the parent; a runaway is contained to its own seat."
    '';
  };

in
{
  options.cycle = {
    owner = mkOption {
      type = types.str;
      default = "skirmitch";
      description = "Who owns the seat scratch subvolumes. The seats run as this user.";
    };
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
          readOnlyPaths = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              Paths this seat's processes see READ-ONLY, enforced by the kernel via a
              bwrap mount namespace rather than by inspecting command text.

              JL ruled this for the operator seat on 2026-09-27 (walk item 7). The
              reason is that the alternative does not converge: Operator's command gate
              tries to recognise every way of writing into the live repositories, and
              each review round finds another spelling it misses - eval, watch, su -c,
              bash -lc, tar --checkpoint-action, rg --pre, plain unlink, chmod, shred,
              sort -o. Measured 2026-09-29: `unlink ~/lonchera/repos/backend/pyproject.toml`
              from that seat would succeed today. At the OS no spelling lands, and the
              gate's write rule becomes a courtesy instead of a wall.

              Empty for a seat that needs none. The Builder's is empty deliberately: he
              merges and pushes in ~/lonchera/repos and builds in ~/lonchera/worktrees.
            '';
          };
          tasksMax = mkOption {
            type = types.int; default = 8192;
            description = ''
              Fork-bomb bound, NOT a working limit. Measured peaks: operator 86 tasks,
              builder 184 (vitest's pool). Builder's estimated worst case for 16 concurrent
              agents is ~3000, and argued the headroom must be generous because hitting
              pids.max makes clone() return EAGAIN and node tends to ABORT rather than back
              off - so the refusal could land on the orchestrator. 8192 is ~2.7x that
              estimate and 1/30th of the per-uid RLIMIT_NPROC (253615) that is the only
              other wall.
            '';
          };
        };
      });
    };
  };

  config = mkIf (seats != { }) {
    environment.etc."cycle/seats.json".source = seatsJson;
    # THE SEATS OWN THESE NUMBERS FROM HERE. JL's ruling, 2026-09-27:
    #   "I want the Seats to be able to manage the limits. They are never malicious, they
    #    are forgetful of garbage collection. If they can use more ram to go faster/more
    #    parallel, the answer is to buy ram, NOT to cripple them."
    #
    # So what nix ships is a DEFAULT and a boom-stop, not a governor. A seat tunes itself
    # without a rebuild and without touching this repo, by dropping a systemd override in
    # its own home - user drop-ins outrank /etc/systemd/user:
    #
    #   ~/.config/systemd/user/cycle-<seat>.slice.d/override.conf
    #       [Slice]
    #       MemoryMax=30G
    #   systemctl --user daemon-reload && systemctl --user restart cycle-<seat>.slice
    #
    # Then run `cycle-limits`, which prints what is actually in force and FAILS if the
    # seat totals have overtaken the parent - the one invariant a seat can break by
    # accident, because breaking it hands the kill to the parent and the victim can be the
    # other seat.
    #
    # bubblewrap is here for the seats' verification sandbox (#3, agreed between both
    # seats 2026-09-27). Operator measured that bwrap today exists ONLY on the PATH the
    # Claude Code harness injects, so a sandboxed run from a plain shell or a timer has
    # none. It is unprivileged; userns and overlayfs already work here without it being
    # system-installed.
    environment.systemPackages = [ seatLauncher sweeper limitsTool pkgs.bubblewrap ];

    # C7-H1: NIX APPLIES THE QUOTA. Until now it did not, and nobody noticed because the
    # limits were already there - set by hand with root on 2026-09-26. So "adding a seat
    # is one attribute" was false: the attribute produced a slice, a database, a redis and
    # a launcher, and then the seat got an UNBOUNDED plain directory, because the one
    # layer that actually enforces was the one step left to human memory.
    #
    # That is the same defect as a comment claiming a check the code never makes. The
    # difference is that this one costs a filled root disk rather than a wrong message.
    systemd.services.cycle-scratch-quota = {
      description = "Create and bound the per-seat scratch subvolumes";
      wantedBy = [ "multi-user.target" ];
      after = [ "mnt-scratch.mount" ];
      requires = [ "mnt-scratch.mount" ];
      # RemainAfterExit, deliberately: a Type=oneshot without it runs TWICE, which is the
      # documented cause of the May 2026 initrd failures on this machine.
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      # A CHANGED QUOTA MUST ACTUALLY APPLY. This service reads the table at RUNTIME, so
      # its unit script does not contain the quota value - and systemd restarts only units
      # whose definition changed. Without this trigger, editing a quota in cycle.seats and
      # rebuilding does NOTHING until somebody remembers to restart the service or reboots.
      # A declared value that silently fails to take effect is the same defect as a comment
      # claiming a check the code never makes; found while raising operator to 64G, which
      # would have been the first instance of it.
      restartTriggers = [ seatsJson ];
      path = [ pkgs.btrfs-progs pkgs.coreutils pkgs.jq pkgs.util-linux ];
      script = ''
        set -uo pipefail
        ROOT="${cfg.scratchRoot}"
        J=/etc/cycle/seats.json

        # PREFLIGHT. This service creates subvolumes and sets limits, so a missing tool
        # must stop it rather than silently change what it does. See the awk incident.
        for t in btrfs jq mountpoint findmnt stat chown; do
          command -v "$t" >/dev/null 2>&1 || { echo "REFUSE: $t is not on PATH"; exit 1; }
        done

        # THE CHECK THAT MATTERS MOST. /mnt/scratch is mounted nofail, so if the bulk disk
        # does not come up this path is an ordinary directory on the OS disk. Creating the
        # seat roots there would hand both seats unbounded scratch on root - which is the
        # exact failure this entire design exists to prevent, arriving silently through
        # the thing meant to prevent it.
        if ! mountpoint -q "$ROOT"; then
          echo "REFUSE: $ROOT is not a mountpoint - the bulk disk did not mount."
          echo "        Creating seat scratch here would put it on the OS disk, unbounded."
          exit 1
        fi

        [ -r "$J" ] || { echo "REFUSE: $J is unreadable"; exit 1; }

        UUID=$(findmnt -no UUID -T "$ROOT") || UUID=""
        [ -n "$UUID" ] || { echo "REFUSE: cannot read the filesystem UUID of $ROOT"; exit 1; }

        if [ "$(cat "/sys/fs/btrfs/$UUID/qgroups/enabled" 2>/dev/null)" != "1" ]; then
          echo "REFUSE: quotas are not enabled on $ROOT. Enable once, by hand:"
          echo "        btrfs quota enable --simple $ROOT"
          echo "        (simple qgroups account by extent lifetime - no backref walks)"
          exit 1
        fi

        rc=0
        for n in $(jq -r '.seats | keys[]' "$J"); do
          pth=$(jq -r --arg n "$n" '.seats[$n].scratch' "$J")
          q=$(jq -r --arg n "$n" '.seats[$n].quota' "$J")

          case "$pth" in
            "$ROOT"/*) ;;
            *) echo "SKIP $n: $pth is not under $ROOT"; rc=1; continue ;;
          esac

          if [ ! -e "$pth" ]; then
            btrfs subvolume create "$pth" || { echo "FAIL $n: could not create $pth"; rc=1; continue; }
            chown ${cfg.owner}:users "$pth"
            echo "created $pth"
          fi

          # Inode 256 is what makes a path a subvolume ROOT. A qgroup limit on a plain
          # directory is accepted and enforces nothing, so this check is the difference
          # between a bound and the appearance of one.
          ino=$(stat -c %i "$pth" 2>/dev/null) || ino=""
          if [ "$ino" != "256" ]; then
            echo "FAIL $n: $pth exists but is NOT a subvolume root (inode ''${ino:-unreadable})."
            echo "     A qgroup limit here would enforce nothing. Refusing to pretend."
            rc=1; continue
          fi

          btrfs qgroup limit "$q" "$pth" || { echo "FAIL $n: could not set the limit"; rc=1; continue; }

          # READ IT BACK. Setting a limit and reporting success without confirming it is
          # the habit this whole module has been unlearning all day.
          rid=$(btrfs inspect-internal rootid "$pth" 2>/dev/null) || rid=""
          got=$(cat "/sys/fs/btrfs/$UUID/qgroups/0_$rid/max_referenced" 2>/dev/null) || got=0
          # Compare against the INTENDED value, not against zero. Builder's point: a
          # -gt 0 test makes "confirmed" mean "some limit exists", which is not the claim
          # the word makes. btrfs suffixes are 1024-based, so numfmt --from=iec matches.
          want=$(numfmt --from=iec "$q" 2>/dev/null) || want=""
          if [ -z "$want" ]; then
            echo "FAIL $n: could not parse the table's quota '$q'"
            rc=1
          elif [ "''${got:-0}" = "$want" ]; then
            echo "$n: $pth rootid=$rid limit=$q, confirmed max_referenced=$got"
          elif [ "''${got:-0}" -gt 0 ]; then
            echo "FAIL $n: limit is $got bytes, the table asks for $q ($want bytes)"
            rc=1
          else
            echo "FAIL $n: the limit read back as 0 - it did NOT take"
            rc=1
          fi
        done
        exit "$rc"
      '';
    };

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
          TasksMax = s.tasksMax;
          CPUWeight = s.cpuWeight;
          # MemoryHigh IS DELIBERATELY UNSET. Not "not tuned yet" - rejected on evidence.
          #
          # memory.high is judged against memory.current, which INCLUDES page cache.
          # Operator measured one suite run: anon peaked at 731 MiB while page cache
          # reached 11.2 GiB, so memory.current peaked at 12.0 GiB - 94% cache. Two
          # suite-sized cache loads, which is simply both seats working, would cross any
          # MemoryHigh worth setting ON CACHE ALONE, with anon at 3% of it.
          #
          # I argued that costs a cache drop rather than a stall. Operator accepted it with
          # the condition I should have stated myself: only if the cache is CLEAN. A test
          # suite writing fixtures makes DIRTY cache, and reclaiming that needs writeback,
          # which is a stall. So MemoryHigh here is a false-positive machine that would
          # ration real work while reporting nothing.
          #
          # The leak detector is NOT a cgroup knob. It is the shape analysis on
          # memory.stat ANON that both seats built - slope, release-at-end, per-process
          # plateau. That is what separates "fix your retention" from "buy more RAM",
          # which is the question JL actually asked.
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
            # BUILDER'S INVARIANT: sum(per-seat MemoryMax) must be STRICTLY UNDER this.
            # 22 + 22 = 44 < 48. Without it the parent trips first whenever both seats are
            # busy, and a memcg OOM picks the worst task in the WHOLE subtree of the cgroup
            # that hit its limit - so one seat's runaway kills the other seat's
            # orchestrator. That is the cross-seat kill this module exists to prevent,
            # reintroduced by its own ceilings. Anyone raising a seat's MemoryMax must
            # raise this first; `cycle-limits` checks it.
            MemoryMax = cfg.parentMemoryMax or "48G";
            # Swap is RAM on this box: zram sits at priority 100 ahead of the disk file and
            # its compressed pages are physical memory. vm.swappiness is 180, so reclaim
            # prefers pushing anon into zram over dropping cache. An unbounded swap ceiling
            # is therefore an unbounded RAM ceiling wearing a disguise - the 09-22 mechanism.
            MemorySwapMax = "8G";
            TasksMax = 16384;
          };
        };
      };

    systemd.user.services.cycle-scratch-sweep = {
      description = "Reap scratch directories whose owning session is dead";
      serviceConfig = { Type = "oneshot"; ExecStart = "${sweeper}/bin/cycle-scratch-sweep"; };
    };
    # ARMED 2026-09-27, by JL, after both seats signed off. It was disabled for a day
    # before this line, and the history matters more than the line does.
    #
    # This reaper deleted a LIVE session's scratchpad on 2026-09-26 at 22:00:07
    # (Builder's b7dbcc30) because `awk` was missing from the service PATH and my code
    # read an empty probe as "dead". A thing that has destroyed data once does not re-arm
    # itself on the next rebuild; somebody decides.
    #
    # WHAT WAS ACTUALLY FIXED between then and now, each measured rather than argued:
    #   - `awk` removed from the sweep AND from the hook, which called it twice more with
    #     2>/dev/null swallowing the command-not-found. Four instances of one bug.
    #   - An unreadable, empty, torn or permission-denied owner is no longer a death
    #     certificate; it takes the 2-day window, not the 1-hour one.
    #   - "Owner is from an older boot" likewise. After a reboot EVERY resumable session
    #     looks like that, so on a 1-hour fuse an armed timer would have reaped the lot.
    #   - A live pid outranks anything unparseable.
    #   - The hook writes the owner atomically, so a write that fails on a full quota no
    #     longer leaves the 0-byte file the old sweep read as "delete me".
    #   - Structural path match replaces a UUID-ish glob; unreadable directories are named
    #     and skipped instead of aborting the whole run in silence.
    #
    # PROVEN BY, not asserted: Builder's acceptance matrix, 16 of 16 against the LIVE
    # gen-258 sweep and hook, written RED first so it failed against the broken version;
    # plus an independent probe of the two cases that used to mean immediate rm -rf.
    #
    # It still refuses more than it reaps. Something is removed only when the owner is
    # provably dead AND the directory has been untouched for the window. Either signal
    # alone keeps it.
    systemd.user.timers.cycle-scratch-sweep = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # OnBootSec + OnUnitActiveSec, NOT OnCalendar. Operator caught this: OnCalendar and
        # OnBootSec are two INDEPENDENT triggers and the earliest one wins, so
        #     OnCalendar = "hourly";  OnBootSec = "2h";
        # fired at the next wall-clock hour - measured, next_elapse 11:00 today with the
        # monotonic trigger still 2h out. The unit carried a "not before 2h after boot"
        # protection that it did not actually provide, which is the same honesty class as
        # a comment claiming a check the code never makes.
        #
        # This pair delivers the guarantee: nothing before boot+2h, then every hour after
        # the previous RUN rather than on the hour. The second form is also better
        # behaved - it will not stampede with every other hourly timer at :00.
        OnBootSec = "2h";
        OnUnitActiveSec = "1h";
        # Persistent=false, deliberately. A persistent timer fires its catch-up run the
        # instant the user manager starts - before login, before any session has been
        # resumed, at the one moment when every scratch directory on disk looks abandoned.
        # That is the worst possible time to let a reaper decide anything.
        Persistent = false;
      };
    };

    environment.etc."cycle/session-start".source = "${sessionHook}/bin/cycle-session-start";
  };
}
