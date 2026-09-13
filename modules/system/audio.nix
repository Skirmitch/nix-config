{ pkgs, ... }:
let
  boseHelper = pkgs.writeShellScriptBin "bose" ''
    set -u
    MAC="''${BOSE_MAC:-BC:87:FA:29:65:4D}"
    DEV="/org/bluez/hci0/dev_''${MAC//:/_}"
    CARD="bluez_card.''${MAC//:/_}"
    SINK="bluez_output.''${MAC//:/_}.1"
    SETTLE="''${BOSE_SETTLE:-12}"     # s from Connected=true to a stable transport (8 s measured)
    COOLDOWN="''${BOSE_COOLDOWN:-30}" # s to ignore the Connected our own reconnect emits
    PATH=${pkgs.lib.makeBinPath (with pkgs; [ bluez pulseaudio pipewire coreutils gnugrep gawk systemd ffmpeg glib ])}:$PATH

    log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

    connected() {
      [ "$(busctl get-property org.bluez "$DEV" org.bluez.Device1 Connected 2>/dev/null | awk '{print $2}')" = true ]
    }

    # Structural signature (see the module comment). Exit 0 healthy, 1 broken,
    # 2 not connected. Prints one line either way.
    check() {
      connected || { echo "not connected"; return 2; }
      local tree sr good bad
      tree=$(busctl tree org.bluez --list --no-pager 2>/dev/null | grep -F "$DEV/")
      sr=$(busctl get-property org.bluez "$DEV" org.bluez.Device1 ServicesResolved 2>/dev/null | awk '{print $2}')
      good=$(grep -cE "^$DEV/sep[0-9]+/fd[0-9]+$" <<<"$tree")
      bad=$(grep -cE "^$DEV/fd[0-9]+$" <<<"$tree")
      if [ "$bad" = 0 ] && [ "$good" -ge 1 ] && [ "$sr" = true ]; then
        echo "healthy: transport under remote endpoint, services resolved"; return 0
      fi
      echo "BROKEN: services_resolved=''${sr:-?} endpoint_transports=$good orphan_transports=$bad"; return 1
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
      printf 'structure : %s\n' "$(check)"
      if probe; then printf 'transport : OK — audio really flows\n'; return 0
      else           printf 'transport : DEAD — profile lies (orphan transport, or the phone holds the stream)\n'; return 1; fi
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
      log "watching $MAC: on Connected=true wait ''${SETTLE}s, check, reclaim once if broken"
      local last=0 now out
      gdbus monitor --system --dest org.bluez --object-path "$DEV" 2>/dev/null \
      | grep --line-buffered -E "PropertiesChanged \('org.bluez.Device1', \{.*'Connected': <true>" \
      | while read -r _; do
          now=$(date +%s)
          if [ $((now - last)) -lt "$COOLDOWN" ]; then log "connected again inside the cooldown, ignoring"; continue; fi
          log "connected, settling ''${SETTLE}s"; sleep "$SETTLE"
          if out=$(check); then log "$out"; continue; fi
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
  #  2. Orphan transport (2026-09-13, the "works only after I reconnect it in
  #     Settings" case): when the headphones power on and initiate the
  #     connection themselves, BlueZ 5.87 configures the A2DP stream before it
  #     has registered the remote endpoints, so the MediaTransport1 object is
  #     created directly under the device path (dev_X/fd0 — transport.c falls
  #     back to device_get_path() when remote_endpoint is NULL) instead of
  #     under the endpoint (dev_X/sep6/fd0), Device1.ServicesResolved stays
  #     false, and every PipeWire Acquire on it returns NotAuthorized
  #     ("Failure in Bluetooth audio transport", node running -> error). The
  #     sink shows Active Profile a2dp-sink, s16le 2ch 48000Hz, SUSPENDED —
  #     healthy-looking. When the PC initiates (manual reconnect) the transport
  #     lands under sep6 and bluetoothd logs "sep6/fd0: fd(N) ready".
  #     "load_remote_sep() Unable to load LastUsed: rseid 6 not found" appears
  #     in BOTH cases and is not the discriminator.
  #
  # So the PROFILE IS NOT A HEALTH CHECK. `bose check` reads the structural
  # signature off D-Bus (fast, silent); `bose status` additionally tries to
  # acquire the transport by playing 0.4 s of silence (the only honest test,
  # 12 s worst case). `bose watch` is the daemon behind the bose-watch user
  # service below: on every Connected=true it waits for the link to settle,
  # runs `check`, and reclaims once if broken — the manual ritual, automated.
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
