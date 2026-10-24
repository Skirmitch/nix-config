{ pkgs, ... }:
let
  boseHelper = pkgs.writeShellScriptBin "bose" ''
    set -u
    PATH=${pkgs.lib.makeBinPath (with pkgs; [ bluez pulseaudio pipewire coreutils gnugrep gawk systemd ffmpeg glib ])}:$PATH

    # The MAC is deliberately NOT in this repo: it was the one piece of private
    # data a public git history carried, and it was redundant - BlueZ already
    # stores the address in /var/lib/bluetooth on this machine. Resolve it from
    # the paired-device list by name instead, and let BOSE_MAC override. This
    # has to sit AFTER the PATH line above, because that is what puts
    # bluetoothctl on the path.
    MAC="''${BOSE_MAC:-$(bluetoothctl devices 2>/dev/null | awk '/Bose/ {print $2; exit}')}"
    if [ -z "$MAC" ]; then
      echo "bose: no paired Bose device found - is bluetoothd up? Set BOSE_MAC to override." >&2
      exit 2
    fi
    DEV="/org/bluez/hci0/dev_''${MAC//:/_}"
    CARD="bluez_card.''${MAC//:/_}"
    SINK="bluez_output.''${MAC//:/_}.1"
    SETTLE="''${BOSE_SETTLE:-12}"     # s from Connected=true to a stable transport (8 s measured)
    COOLDOWN="''${BOSE_COOLDOWN:-30}" # s to ignore the Connected our own reconnect emits

    log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

    connected() {
      [ "$(busctl get-property org.bluez "$DEV" org.bluez.Device1 Connected 2>/dev/null | awk '{print $2}')" = true ]
    }

    # The D-Bus shape of the connection, as CONTEXT for the log line — it does
    # not decide health (see the module comment: with the 5.87 cache patch a
    # headset-initiated connect still yields a sep-less transport path and
    # ServicesResolved=false, and audio flows).
    shape() {
      local tree sr good bad st
      tree=$(busctl tree org.bluez --list --no-pager 2>/dev/null | grep -F "$DEV/")
      sr=$(busctl get-property org.bluez "$DEV" org.bluez.Device1 ServicesResolved 2>/dev/null | awk '{print $2}')
      good=$(grep -cE "^$DEV/sep[0-9]+/fd[0-9]+$" <<<"$tree")
      bad=$(grep -cE "^$DEV/fd[0-9]+$" <<<"$tree")
      st=$(for t in $(grep -E "^$DEV(/sep[0-9]+)?/fd[0-9]+$" <<<"$tree"); do busctl get-property org.bluez "$t" org.bluez.MediaTransport1 State 2>/dev/null | awk '{print $2}'; done | tr -d '"' | paste -sd, -)
      echo "services_resolved=''${sr:-?} endpoint_transports=$good orphan_transports=$bad transport_state=''${st:-none}"
    }

    # Health = PipeWire can acquire the transport and stream through it: 0.4 s
    # of digital silence into the sink, 12 s timeout, sub-second when healthy.
    # Exit 0 healthy, 1 dead, 2 not connected. Prints one line either way.
    check() {
      connected || { echo "not connected"; return 2; }
      if probe; then echo "healthy: transport acquired, audio flows ($(shape))"; return 0; fi
      echo "DEAD: transport not acquirable ($(shape))"; return 1
    }

    probe() {  # try to acquire the transport: 0.4 s of silence, 12 s worst case
      local t; t=$(mktemp --suffix=.wav)
      ffmpeg -nostdin -loglevel quiet -f lavfi -i anullsrc=r=48000:cl=stereo -t 0.4 -y "$t" 2>/dev/null
      timeout 12 pw-play --target "$SINK" "$t" >/dev/null 2>&1; local rc=$?
      rm -f "$t"; return $rc
    }

    status() {
      local prof fmt
      prof=$(pactl list cards 2>/dev/null | awk "/Name: $CARD/,/^\$/" | grep 'Active Profile' | sed 's/.*: //')
      fmt=$(pactl list short sinks 2>/dev/null | grep -F "$SINK" | cut -f4-)
      printf 'profile   : %s\n' "''${prof:-<card absent>}"
      printf 'format    : %s\n' "''${fmt:-<no sink>}"
      printf 'transport : %s\n' "$(check)"
    }

    reclaim() {
      echo "reclaiming $MAC for this PC..."
      bluetoothctl disconnect "$MAC" >/dev/null 2>&1
      sleep 4
      bluetoothctl connect "$MAC" >/dev/null 2>&1
      sleep 7
      pactl set-card-profile "$CARD" a2dp-sink >/dev/null 2>&1 || true   # AAC, best available
    }

    watch() {
      log "watching $MAC: on Connected=true wait ''${SETTLE}s, probe the transport, reclaim once if dead"
      local last=0 now out
      gdbus monitor --system --dest org.bluez --object-path "$DEV" 2>/dev/null \
      | grep --line-buffered -E "PropertiesChanged \('org.bluez.Device1', \{.*'Connected': <true>" \
      | while read -r _; do
          now=$(date +%s)
          if [ $((now - last)) -lt "$COOLDOWN" ]; then log "connected again inside the cooldown, ignoring"; continue; fi
          log "connected, settling ''${SETTLE}s"; sleep "$SETTLE"
          out=$(check); rc=$?
          case $rc in
            0) log "$out"; continue ;;
            2) log "not connected at settle (the headset flaps on power-on); waiting for its next connect"; continue ;;
          esac
          log "$out -> reclaiming"
          last=$(date +%s)
          bluetoothctl disconnect "$MAC" >/dev/null 2>&1; sleep 4; bluetoothctl connect "$MAC" >/dev/null 2>&1
          sleep "$SETTLE"
          if out=$(check); then log "after reclaim: $out"; else log "after reclaim STILL $out (leaving it; next connect retries)"; fi
        done
      log "gdbus monitor ended"; return 1   # systemd restarts us
    }

    case "''${1:-reclaim}" in
      check)   check ;;
      status)  status ;;
      watch)   watch ;;
      reclaim|"") reclaim; status ;;
      *) echo "usage: bose [reclaim|status|check|watch]" >&2; exit 2 ;;
    esac
  '';
in
{
  # --- SOUND ---
  services.pipewire = { enable = true; pulse.enable = true; };

  # --- BLUETOOTH AUDIO: A2DP ONLY, NEVER HEADSET ---
  #
  # Diana never uses a Bluetooth microphone — the Sennheiser USB mic is the
  # only input. So every HSP/HFP ("headset") code path is dead weight here,
  # and worse than dead weight: on 2026-08-26 the Bose QC Ultra connected
  # with no A2DP endpoint negotiated, leaving only headset profiles, and
  # PipeWire happily ran the headphones at s16le 1ch 16000Hz — telephone
  # mono — while WirePlumber logged "Could not find valid non-headset
  # profile, not switching" because there was genuinely nothing to switch to.
  #
  # Removing the headset roles entirely means that failure can no longer
  # degrade quietly: without A2DP the card lands on "off" (obvious, fixed by
  # a reconnect) instead of silently downgrading to 16 kHz mono.
  services.pipewire.wireplumber.extraConfig."51-bluez-a2dp-only" = {
    "monitor.bluez.properties" = {
      # No hsp_hs / hfp_hf → no headset profile is ever created.
      "bluez5.roles" = [ "a2dp_sink" "a2dp_source" ];
      # Highest quality first. AAC is what the QC Ultra actually prefers.
      "bluez5.codecs" = [ "aac" "sbc_xq" "sbc" ];
      "bluez5.enable-sbc-xq" = true;
      "bluez5.enable-msbc" = false;      # mSBC is HFP-only
      "bluez5.hfphsp-backend" = "none";  # kill the HFP/HSP backend outright
    };
    "wireplumber.settings" = {
      # Nothing may drag a headset into headset mode when an app records.
      "bluetooth.autoswitch-to-headset-profile" = false;
      "bluetooth.profile-preference" = "quality";
    };
  };

  # --- `bose` HELPER + WATCHDOG ---
  #
  # Two distinct ways the QC Ultra ends up "connected but silent", both seen
  # live, both fixed by a disconnect/reconnect:
  #
  #  1. Multipoint (2026-08-26): the phone holds the A2DP stream, BlueZ
  #     refuses the PC's transport with org.bluez.Error.NotAuthorized after
  #     "a2dp-sink profile connect failed: Device or resource busy".
  #  2. BlueZ 5.87 cache regression (2026-09-13, the "works only after I
  #     reconnect it in Settings" case; patched in networking.nix). When the
  #     headphones power on and initiate the connection, bluetoothd configures
  #     the stream before it has resolved the remote endpoint, so the
  #     MediaTransport1 object lands at dev_X/fd0 instead of dev_X/sep6/fd0
  #     and Device1.ServicesResolved stays false. UNPATCHED that transport was
  #     "active" with a stale owner and every PipeWire Acquire returned
  #     NotAuthorized ("Failure in Bluetooth audio transport", node running ->
  #     error) while the card kept reporting a2dp-sink / s16le 2ch 48000Hz.
  #     PATCHED (measured 2026-09-13 11:30 on a real power-on): the transport
  #     still has the sep-less path and ServicesResolved=false, but it is
  #     "idle", PipeWire acquires it in under a second, and audio flows.
  #
  # Lessons encoded below: the PROFILE IS NOT A HEALTH CHECK, and neither is
  # the D-Bus shape — only acquiring the transport is. `bose check` plays 0.4 s
  # of digital silence into the sink (sub-second when healthy, 12 s timeout
  # when dead) and prints the shape as context. `bose status` adds the
  # profile/format lines. `bose watch` is the daemon behind the bose-watch user
  # service: on every Connected=true it waits for the link to settle, runs
  # `check`, and reclaims once only if the probe fails — the manual ritual,
  # automated, and silent on a healthy connect. (An earlier revision reclaimed
  # on the shape alone; with the patched daemon that was a false positive on
  # every connect: a 4 s audio hiccup for nothing.)
  environment.systemPackages = with pkgs; [
    pulseaudio paprefs pavucontrol
    boseHelper
  ];

  systemd.user.services.bose-watch = {
    description = "Reclaim the Bose QC Ultra when it auto-connects with an orphan A2DP transport";
    wantedBy = [ "default.target" ];
    after = [ "wireplumber.service" ];
    serviceConfig = {
      ExecStart = "${boseHelper}/bin/bose watch";
      Restart = "always";
      RestartSec = 5;
    };
  };
}
