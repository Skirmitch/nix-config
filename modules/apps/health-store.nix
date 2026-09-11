{ pkgs, inputs, lib, ... }:
let
  hc = inputs.hc-sync.packages.${pkgs.system};
  stateDir = "/var/lib/health";
  # Diana's tailnet address. Datasette binds here + loopback, NEVER 0.0.0.0:
  # networking.nix also trusts the hotspot interface, so a wildcard bind would
  # hand the health database to any hotspot client.
  tailnetIp = "100.99.204.36";
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
  # Secrets live in ${stateDir}/env (root:skirmitch 0640, written by hand):
  #   HC_S3_BUCKET=skirmitch-health-inbox-<account>
  #   HC_AWS_PROFILE=hc-reader          # read-only IAM user, ~/.aws of skirmitch
  #   NS_URL=https://nightscout.skirmitch.com
  #   NS_TOKEN=<read-only subject token>
  # Nothing secret is in this repo.

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
    serviceConfig = {
      Type = "oneshot";
      User = "skirmitch";
      Group = "users";
      EnvironmentFile = "-${stateDir}/env";
      Environment = [ "HC_DB=${stateDir}/hc.sqlite" "HC_INBOX_DIR=${stateDir}/inbox" "HOME=/home/skirmitch" ];
      ExecStart = "${hc.hc-store}/bin/hc-import run";
      # 96 runs a day would be noise; the importer prefixes WARN/ERROR with
      # <4>/<3> so they pass this filter, INFO does not.
      LogLevelMax = "notice";
    };
  };
  systemd.timers.hc-import = {
    description = "Health store import every 15 min";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitInactiveSec = "15min";
      AccuracySec = "1min";
      Persistent = true;
    };
  };

  # Nightly consistent copy next to the live file (both persisted). The S3
  # archive is the real backup; this covers "I ran a bad UPDATE by hand".
  systemd.services.hc-backup = {
    description = "Nightly SQLite backup of the health store";
    serviceConfig = {
      Type = "oneshot";
      User = "skirmitch";
      Group = "users";
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
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "03:30"; Persistent = true; };
  };

  # Datasette: read-only browser over the store, reachable from the phone via
  # the tailnet. WAL reads while hc-import writes are fine (not --immutable).
  systemd.services.datasette = {
    description = "Datasette over the health store (tailnet + loopback)";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "skirmitch";
      Group = "users";
      Restart = "on-failure";
      RestartSec = "10s";
      ExecStartPre = [
        # Seen 2026-09-09 18:30:32 at boot: "could not bind on any address" -
        # tailscaled was up but the interface had no address yet. Wait for it
        # (bounded) instead of relying on Restart= to win the race.
        (pkgs.writeShellScript "wait-tailnet-ip" ''
          for _ in $(seq 60); do
            ${pkgs.iproute2}/bin/ip -4 addr show dev tailscale0 2>/dev/null | grep -q '${tailnetIp}' && exit 0
            sleep 1
          done
          echo "tailscale0 has no ${tailnetIp} after 60s; starting anyway" >&2
        '')
        "${hc.hc-store}/bin/hc-import --db ${stateDir}/hc.sqlite --inbox ${stateDir}/inbox init"
      ];
      # Bind to the tailnet IP only; loopback users go through the tailnet IP too.
      ExecStart = "${hc.datasette}/bin/datasette serve ${stateDir}/hc.sqlite -h ${tailnetIp} -p 8001 --metadata ${hc.hc-store.datasetteMetadata} --setting sql_time_limit_ms 5000 --setting max_returned_rows 5000 --setting default_page_size 100";
      Environment = [ "HC_DB=${stateDir}/hc.sqlite" ];
    };
  };
  # tailscale0 is a trusted interface (tailscale.nix), so no port opening here.

  # health-status: one-screen summary, also what to run when "nothing arrived".
  environment.shellAliases.health-status = "HC_DB=${stateDir}/hc.sqlite HC_INBOX_DIR=${stateDir}/inbox hc-import status";
}
