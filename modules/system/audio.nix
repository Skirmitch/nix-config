{ pkgs, ... }: {
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

  # --- `bose` HELPER ---
  #
  # Why this exists: the Bose is multipoint. When the phone holds the A2DP
  # stream, BlueZ refuses the PC's transport with org.bluez.Error.NotAuthorized
  # (preceded by "a2dp-sink profile connect failed: Device or resource busy"
  # and a stale-cache "load_remote_sep() Unable to load LastUsed: rseid N not
  # found"). PipeWire still reports Active Profile a2dp-sink and the sink as
  # RUNNING — so the PROFILE IS NOT A HEALTH CHECK. Only acquiring the
  # transport proves audio actually flows. A disconnect/reconnect is what makes
  # the headphones hand the stream back to this machine.
  environment.systemPackages = with pkgs; [
    pulseaudio paprefs pavucontrol

    (pkgs.writeShellScriptBin "bose" ''
      set -u
      MAC="''${BOSE_MAC:-BC:87:FA:29:65:4D}"
      CARD="bluez_card.''${MAC//:/_}"
      SINK="bluez_output.''${MAC//:/_}.1"
      PATH=${pkgs.lib.makeBinPath (with pkgs; [ bluez pulseaudio pipewire coreutils gnugrep gawk systemd ffmpeg ])}:$PATH

      probe() {  # the only honest test: try to acquire the transport
        local t; t=$(mktemp --suffix=.wav)
        ffmpeg -nostdin -loglevel quiet -f lavfi -i anullsrc=r=48000:cl=stereo -t 0.4 -y "$t" 2>/dev/null
        timeout 12 pw-play --target "$SINK" "$t" >/dev/null 2>&1; local rc=$?
        rm -f "$t"; return $rc
      }

      status() {
        local prof; prof=$(pactl list cards 2>/dev/null | awk "/Name: $CARD/,/^\$/" | grep 'Active Profile' | sed 's/.*: //')
        local fmt;  fmt=$(pactl list short sinks 2>/dev/null | grep -F "$SINK" | cut -f4-)
        printf 'profile   : %s\n' "''${prof:-<card absent>}"
        printf 'format    : %s\n' "''${fmt:-<no sink>}"
        if probe; then printf 'transport : OK — audio really flows\n'; return 0
        else           printf 'transport : DEAD — profile lies, the phone likely holds the stream\n'; return 1; fi
      }

      case "''${1:-reclaim}" in
        status) status ;;
        reclaim|"")
          echo "reclaiming $MAC for this PC..."
          bluetoothctl disconnect "$MAC" >/dev/null 2>&1
          sleep 4
          bluetoothctl connect "$MAC" >/dev/null 2>&1
          sleep 7
          pactl set-card-profile "$CARD" a2dp-sink >/dev/null 2>&1 || true   # AAC, best available
          status ;;
        *) echo "usage: bose [reclaim|status]" >&2; exit 2 ;;
      esac
    '')
  ];
}
