{ pkgs, inputs, lib, ... }:
let
  hc = inputs.hc-sync.packages.${pkgs.system};
  stateDir = "/var/lib/health";

  # Sandbox shared by the three units. Datasette is the reason it exists: it is
  # the only long-lived network listener here, it accepts arbitrary SQL from any
  # tailnet peer, and skirmitch is in wheel - so a bug in Datasette or one of its
  # dependencies used to reach ~/.ssh, ~/.aws, ~/.config/gh and sudo (finding 40,
  # v3 65). User=skirmitch stays: it is what lets health-mcp, hc-export and
  # Datasette open the same file without a group dance; the sandbox takes away
  # everything that identity does NOT need.
  #   ProtectSystem=strict + ReadWritePaths: /var/lib/health is the only writable
  #     path. WAL readers must be able to write -shm/-wal, so Datasette needs it
  #     too - it is not --immutable.
  #   AF_NETLINK is NOT optional: glibc's getaddrinfo probes netlink for the
  #     interface list, so boto3 (hc-import) and the tailnet address lookup in
  #     the Datasette wrapper both fail without it, with a misleading DNS error.
  #   hc-backup needs none of the network families; it shares the set so there is
  #     ONE hardening definition to keep correct, and inheriting an unused
  #     capability is cheaper than a second, subtly different block.
  hardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ReadWritePaths = [ stateDir ];
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
    RestrictSUIDSGID = true;
    LockPersonality = true;
    SystemCallFilter = [ "@system-service" ];
  };

  # Every unit that touches the store must refuse to start unless the bind mount
  # from /persist is actually there. /var/lib is on the wiped @root subvolume and
  # var-lib-health.mount is only WantedBy=local-fs.target, so a failed mount does
  # not fail the target: systemd-tmpfiles would then recreate the directory on
  # @root, `hc-import init` would lay a fresh schema into it and everything would
  # look healthy while writing to a subvolume that the next boot deletes
  # (finding 31, v3 58). The harm is unreachable today - the mount source is
  # created in the initrd - but this is the correct dependency and it is one line.
  requiresStore = { RequiresMountsFor = stateDir; };
in {
  # --- HEALTH STORE: canonical copy of Health Connect (+ Nightscout) ---
  #
  # Pipeline (project: ~/Projects/hc-sync, flake input `hc-sync`):
  #   phone (hc-sync app) -> AWS HTTP API + Lambda -> S3 archive
  #   -> here: hc-import pulls new batches every 15 min into an SQLite file
  #   -> Datasette (browse from the phone over the tailnet) + health-mcp
  #      (Claude Code / Desktop, stdio) + hc-export (parquet/csv/FHIR).
  #
  # Why SQLite and not the Postgres already running on this box: Datasette
  # is SQLite-native, one file backs up with `.backup`, and the S3 archive is
  # the source of truth anyway - this file is a materialisation that
  # `hc-import pull --all` can rebuild from scratch.
  #
  # Secrets live in ${stateDir}/env (skirmitch:users 0640, written by hand -
  # exactly what docs/runbook.md section 2 creates; there is no `skirmitch`
  # GROUP on this box, so the old `root:skirmitch` in this comment was not even
  # copy-pasteable - finding 35/12, v3 62):
  #   HC_S3_BUCKET=skirmitch-health-inbox-<account>
  #   HC_AWS_PROFILE=hc-reader          # read-only IAM user, ~/.aws of skirmitch
  #   NS_URL=https://nightscout.skirmitch.com
  #   NS_TOKEN=<read-only subject token>
  # Nothing secret is in this repo. UNTIL THAT FILE EXISTS hc-import EXITS 2 AND
  # THE UNIT SHOWS `failed` EVERY 15 MINUTES, ON PURPOSE: a green timer that
  # quietly did nothing is what hid the missing env file for 89 runs.

  # awscli2 is also in modules/apps/programming.nix; both entries are literally
  # `pkgs.awscli2`, so buildEnv links one path and no collision results. Kept
  # here deliberately: this module's dependency on it (runbook step 1, reading
  # the bucket by hand) should not be invisible if programming.nix ever changes.
  environment.systemPackages = [ hc.hc-store hc.datasette pkgs.awscli2 ];

  # Impermanence: /var/lib is on the wiped @root subvolume. Without this line
  # the whole health database vanishes on reboot, silently.
  environment.persistence."/persist".directories = [
    { directory = stateDir; user = "skirmitch"; group = "users"; mode = "0750"; }
  ];

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 skirmitch users -"
    "d ${stateDir}/inbox 0750 skirmitch users -"
    "d ${stateDir}/backups 0750 skirmitch users -"
  ];

  # The importer runs as skirmitch so it can use ~/.aws/credentials
  # ([hc-reader] profile) and so the MCP server (also skirmitch) and Datasette
  # read the same file without a group dance.
  systemd.services.hc-import = {
    description = "Pull Health Connect batches from S3 and apply them to the store";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = requiresStore;
    serviceConfig = hardening // {
      Type = "oneshot";
      User = "skirmitch";
      Group = "users";
      # The `-` stays. Without it systemd fails the unit BEFORE ExecStart, and
      # `apply` + the Nightscout mirror - which are configured independently of
      # S3 - would never run. The loud signal is the importer's own exit 2.
      EnvironmentFile = "-${stateDir}/env";
      Environment = [ "HC_DB=${stateDir}/hc.sqlite" "HC_INBOX_DIR=${stateDir}/inbox" "HOME=/home/skirmitch" ];
      # ~/.aws/credentials ([hc-reader]) is the one thing outside stateDir this
      # unit reads; nothing in $HOME is ever written.
      ProtectHome = "read-only";
      ExecStart = "${hc.hc-store}/bin/hc-import run";
      # NO LogLevelMax. It was set to notice to keep 96 runs a day quiet, and it
      # worked - it also deleted 304 real log lines and would have deleted the
      # traceback of the first genuine failure, because systemd tags UNPREFIXED
      # stderr at info(6) and a Python traceback carries no prefix (findings
      # 28/29/30, v3 56/57). The importer still prefixes every line with the
      # sd-daemon <3>/<4>/<6> priorities, so `journalctl -p warning -u hc-import`
      # gives back the quiet view without hiding anything. ~300 INFO lines a day
      # against an 87 MB journal is not noise.
    };
  };
  systemd.timers.hc-import = {
    description = "Health store import every 15 min";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitInactiveSec = "15min";
      AccuracySec = "1min";
      # No Persistent=: it only affects OnCalendar= timers (systemd.timer(5)),
      # and this one is purely monotonic - the line promised a catch-up it never
      # performed (finding 37, v3 59). The real catch-up story lives in the
      # importer: OnBootSec=3min fires after downtime and `pull` walks from the
      # last successful pull day (30 days by default, the whole prefix past 90),
      # so a month with Diana switched off needs no human step.
      # OnUnitInactiveSec is measured from the last inactive-OR-FAILED
      # transition, so the timer keeps firing while the unit exits 2.
    };
  };

  # Nightly consistent copy next to the live file (both persisted). The S3
  # archive is the real backup; this covers "I ran a bad UPDATE by hand".
  systemd.services.hc-backup = {
    description = "Nightly SQLite backup of the health store";
    unitConfig = requiresStore;
    serviceConfig = hardening // {
      Type = "oneshot";
      User = "skirmitch";
      Group = "users";
      ProtectHome = true;
      ExecStart = pkgs.writeShellScript "hc-backup" ''
        set -euo pipefail
        out="${stateDir}/backups/hc-$(date +%F).sqlite"
        ${pkgs.sqlite}/bin/sqlite3 ${stateDir}/hc.sqlite ".backup '$out'"
        ${pkgs.gzip}/bin/gzip -f "$out"
        ls -1t ${stateDir}/backups/hc-*.sqlite.gz | tail -n +15 | xargs -r rm -f
      '';
    };
  };
  systemd.timers.hc-backup = {
    description = "Nightly health-store backup";
    wantedBy = [ "timers.target" ];
    # Persistent= here is real (OnCalendar=), and it only started working once
    # /var/lib/systemd/timers was persisted - the stamp file lived on the wiped
    # @root, so a backup missed while the box was off was never caught up
    # (v3 60). See hosts/diana/impermanence.nix.
    timerConfig = { OnCalendar = "03:30"; Persistent = true; };
  };

  # Datasette: read-only browser over the store, reachable from the phone via
  # the tailnet. WAL reads while hc-import writes are fine (not --immutable).
  systemd.services.datasette = {
    description = "Datasette over the health store (tailnet + loopback)";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig = requiresStore // {
      # Retry forever and quietly: the only reason the start sequence gives up
      # is "the tailnet address is not up yet", which is a wait, not a fault.
      # With the default rate limiter (5 starts / 10 s) a 90 s wait never trips
      # it anyway, so this only removes a trap for a future shorter timeout.
      StartLimitIntervalSec = 0;
    };
    serviceConfig = hardening // {
      User = "skirmitch";
      Group = "users";
      # Datasette reads exactly one path and nothing from $HOME.
      ProtectHome = true;
      Restart = "on-failure";
      RestartSec = "30s";
      # /run/datasette, created at every start and owned by skirmitch:users,
      # removed when the unit stops. ProtectSystem=strict mounts the whole
      # hierarchy read-only, but RuntimeDirectory= is exempt by construction -
      # systemd.exec(5) under ProtectSystem=: "StateDirectory=, LogsDirectory=,
      # ... and related directory settings (see below) also exclude the specific
      # directories from the effect of ProtectSystem=". It is the handoff
      # between the two Exec* phases below; nothing else uses it.
      RuntimeDirectory = "datasette";
      # The tailnet wait lives in start-pre and is bounded at 90 s; the DEFAULT
      # start timeout is also exactly 90 s, so without this the unit would be
      # killed by the timeout in the same second the loop gives up and the
      # exit-75 line would never be logged.
      TimeoutStartSec = "150s";
      ExecStartPre = [
        # `init` is the ONLY path that creates or upgrades the schema: since the
        # DDL is gated on a schema hash, running it on every start (including
        # the 30 s retries below) is a no-op, not the 14-view drop/recreate
        # churn it used to be. `hc-import init --force` is the manual repair.
        "${hc.hc-store}/bin/hc-import --db ${stateDir}/hc.sqlite --inbox ${stateDir}/inbox init"
        # THE WAIT BELONGS HERE, NOT IN ExecStart: a Type=simple unit is active
        # the moment the shell forks, so with the loop inside ExecStart the unit
        # read `active (running)` for up to 90 s while nothing listened on 8001,
        # and with tailscale down it cycled active(90 s) -> failed -> active,
        # i.e. `systemctl is-active datasette` said yes ~75 % of the time. In
        # start-pre the unit stays `activating (start-pre)` for the wait, so
        # `systemctl is-active` means listening. (Same class of defect as the
        # green-but-idle hc-import timer above.)
        (pkgs.writeShellScript "datasette-wait-tailnet" ''
          set -u
          for _ in $(${pkgs.coreutils}/bin/seq 90); do
            ip=$(${pkgs.tailscale}/bin/tailscale ip -4 2>/dev/null \
                 | ${pkgs.gnugrep}/bin/grep -m1 -E '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+$') || ip=""
            if [ -n "$ip" ]; then
              printf '%s\n' "$ip" > "$RUNTIME_DIRECTORY/ip"
              echo "<6>tailnet address $ip written to $RUNTIME_DIRECTORY/ip" >&2
              exit 0
            fi
            ${pkgs.coreutils}/bin/sleep 1
          done
          echo "<3>no 100.64.0.0/10 address from 'tailscale ip -4' after 90s; retrying in 30s" >&2
          exit 75
        '')
      ];
      # Bind the tailnet address, NEVER 0.0.0.0: networking.nix also trusts the
      # hotspot interface, so a wildcard bind would hand the health database to
      # any hotspot client. Today that address is 100.99.204.36 (the value the
      # runbook tells you to open), but it is DERIVED at start, not pinned:
      # `tailscale ip -4` is asked for it by the start-pre above, and only a
      # 100.64.0.0/10 answer is accepted. Seen 2026-09-09 18:30:32: "could not
      # bind on any address" at boot because tailscaled was up but the interface
      # had no address yet. A re-registration (loss of /persist/var/lib/tailscale)
      # or a tailnet migration used to mean editing this file; now it just works.
      # The unprivileged `tailscale` call is fine: tailscaled.sock is 0666 and
      # connect(2) is exempt from ProtectSystem=strict's read-only check.
      # Exit 75 (EX_TEMPFAIL) from EITHER phase + Restart=on-failure (which
      # covers a failed ExecStartPre) = retry every 30 s forever.
      ExecStart = pkgs.writeShellScript "datasette-tailnet" ''
        set -u
        ip=$(${pkgs.coreutils}/bin/cat "$RUNTIME_DIRECTORY/ip" 2>/dev/null) || ip=""
        if [ -z "$ip" ]; then
          echo "<3>no address in $RUNTIME_DIRECTORY/ip; retrying in 30s" >&2
          exit 75
        fi
        echo "<6>binding Datasette to tailnet address $ip" >&2
        exec ${hc.datasette}/bin/datasette serve ${stateDir}/hc.sqlite \
          -h "$ip" -p 8001 \
          --metadata ${hc.hc-store.datasetteMetadata} \
          --setting sql_time_limit_ms 5000 \
          --setting max_returned_rows 5000 \
          --setting default_page_size 100
      '';
      Environment = [ "HC_DB=${stateDir}/hc.sqlite" ];
    };
  };
  # tailscale0 is a trusted interface (tailscale.nix), so no port opening here.

  # health-status: one-screen summary, also what to run when "nothing arrived".
  # `hc-import status` is genuinely read-only now (it opens file:...?mode=ro and
  # runs no DDL), and it exits 1 with "store not initialised" rather than
  # creating an empty database - so it is safe to reach for while the store looks
  # sick. Still run it as skirmitch, NOT under sudo: a mode=ro connection may
  # create hc.sqlite-shm when the directory is writable and cannot checkpoint it
  # away again, so a root-owned -shm left behind while datasette is down locks
  # the importer out. It is a shell alias, i.e. interactive shells only:
  # scripts and remote `ssh diana '...'` must spell out the ExecStart form below.
  environment.shellAliases.health-status = "HC_DB=${stateDir}/hc.sqlite HC_INBOX_DIR=${stateDir}/inbox hc-import status";
}
