{ pkgs, ... }:
let
  # --- Boox: the BOOX Note Air 3 C as a window on Diana ---------------------
  #
  # Draw natively on the tablet, where the EMR pen and the paper film actually
  # live, and ship only PIXELS to Diana. Every design that sends pen events the
  # other way and renders the stroke here destroys the one property worth having.
  #
  # Everything below was measured against the real device on 2026-10-19
  # (NoteAir3C, Android 12 / SDK 32, BOOX firmware 4.2-rel_0519):
  #
  #   * display 0 is 1860x2480 @ 300dpi, the only display.
  #   * `h264 OMX.qcom.video.encoder.avc (hw)` is present, so the BOOX H.264
  #     landmine upstream documents for the Note X does NOT apply here and no
  #     VP8/VP9 fallback is needed. There is no h265/av1 encoder at all.
  #   * That encoder REFUSES a 2480-tall surface: scrcpy throws
  #     `MediaCodec$CodecException: Error 0xfffffff4` once, logs "Applying video
  #     encoder constraints" and retries at 1088x1452. Asking for 1452 up front
  #     skips the failed attempt -- verified, 0 exceptions.
  #   * The framebuffer is full RGB: no grayscale, no dither, no ghosting. The
  #     mirror looks BETTER than the Kaleido 3 panel, which is 4096 muted
  #     colours at 150 ppi.
  #   * `--no-control` is deliberate, for two reasons. scrcpy#5309 on
  #     BOOX/Android 12 threw SecurityException "calling package android does
  #     not match caller's uid 2000" inside Controller init, which --no-control
  #     never constructs; and with control off, a stray mouse can never land a
  #     mark on the canvas. JL holds the pen - Diana never needs to drive.
  #   * `scrcpy -n -w` is refused at PARSE time ("Cannot request to stay awake
  #     if control is disabled"), so keeping the tablet awake is a device
  #     setting, never a scrcpy flag. See the sleep note on the retry loop.
  #
  # ROTATION is not a scrcpy feature to add - scrcpy already follows device
  # rotation and resizes the window. It had simply never seen one, because the
  # panel was locked: accelerometer_rotation=0, user_rotation=0, while
  # mSupportAutoRotation=true. The fix lives on the tablet:
  #     adb -s <target> shell settings put system accelerometer_rotation 1
  # BOOX's own rotate control sets the same system rotation and works
  # identically. Independently, MOD+Left / MOD+Right rotate the WINDOW on Diana
  # (client-side, works under --no-control); MOD+r is different and does need
  # control, so it is unavailable here by design.
  # Caveat: a tablet lying FLAT gives the accelerometer an ambiguous reading -
  # the exact posture for drawing. If it misbehaves, set it back to 0.
  #
  # `--max-size` caps the LARGER dimension, so the pixel budget is identical
  # either way: 1088x1452 portrait, 1452x1089 landscape.

  booxIcon = pkgs.writeText "boox.svg" ''
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
      <rect x="11" y="5" width="38" height="54" rx="4.5" fill="#2e3436"/>
      <rect x="15" y="10" width="30" height="41" rx="1.5" fill="#f6f5ef"/>
      <rect x="19" y="16" width="12" height="9" rx="1" fill="none" stroke="#3465a4" stroke-width="2"/>
      <path d="M25 26 L25 33" fill="none" stroke="#3465a4" stroke-width="2" stroke-linecap="round"/>
      <path d="M22 30.5 L25 34 L28 30.5" fill="none" stroke="#3465a4" stroke-width="2"
            stroke-linecap="round" stroke-linejoin="round"/>
      <rect x="19" y="35" width="12" height="9" rx="1" fill="none" stroke="#3465a4" stroke-width="2"/>
      <circle cx="30" cy="55" r="1.8" fill="#888a85"/>
      <g transform="rotate(32 44 34)">
        <rect x="41.8" y="12" width="4.4" height="24" rx="2.2" fill="#babdb6"/>
        <rect x="41.8" y="31" width="4.4" height="5" fill="#8d9089"/>
        <path d="M41.8 36 L46.2 36 L44 42 Z" fill="#2e3436"/>
      </g>
    </svg>
  '';

  boox = pkgs.writeShellApplication {
    name = "boox";
    runtimeInputs = with pkgs; [
      scrcpy        # carries its own matching scrcpy-server.jar
      android-tools # adb
      libnotify     # notify-send: this is launched from GNOME, so there is no
                    # terminal to print an error into
    ];
    # errexit is deliberately ABSENT. The retry loop below inspects scrcpy's
    # exit status by hand, and `set -e` would kill the script on the very
    # disconnect it exists to recover from.
    bashOptions = [ "nounset" "pipefail" ];
    text = ''
      PORT=5555
      MAXSIZE="''${BOOX_MAXSIZE:-1452}"
      TITLE="''${BOOX_TITLE:-Boox}"
      RETRY_DELAY="''${BOOX_RETRY_DELAY:-5}"
      MAX_FAILS="''${BOOX_MAX_FAILS:-60}"   # ~5 min of a sleeping tablet

      # Remembering the address is what makes this a double-clickable app: a
      # GNOME launch has no environment to carry BOOX_IP, and `adb` cannot
      # discover the tablet itself (nixpkgs' android-tools is built WITHOUT the
      # mDNS backend - `adb mdns check` answers "mdns is not supported by this
      # version of adb" even though `adb help` lists the subcommand).
      STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/boox"
      mkdir -p "$STATE_DIR"
      IP_FILE="$STATE_DIR/ip"

      IP="''${BOOX_IP:-}"
      if [ -z "$IP" ] && [ -r "$IP_FILE" ]; then IP="$(cat "$IP_FILE")"; fi

      notify() { notify-send -a Boox -i boox "$1" "$2" >/dev/null 2>&1 || true; }

      # `adb connect` reports success into an OFFLINE transport - observed
      # directly on 2026-10-19 - so never believe it without a live shell.
      alive()      { adb -s "$1" shell true >/dev/null 2>&1; }
      net_target() { adb devices | awk '$2=="device" && $1 ~ /:/  {print $1; exit}'; }
      usb_serial() { adb devices | awk '$2=="device" && $1 !~ /:/ {print $1; exit}'; }

      # 1. already connected over the network
      TARGET="$(net_target)"

      # 2. remembered address - tcpip mode may still be armed
      if [ -z "$TARGET" ] && [ -n "$IP" ]; then
        adb connect "$IP:$PORT" >/dev/null 2>&1
        TARGET="$(net_target)"
      fi

      # 3. the cable, once, to arm tcpip mode and learn the address.
      #    tcpip mode survives until the TABLET reboots; Diana rebooting is
      #    irrelevant. No udev rule is needed for any of this: 70-uaccess.rules
      #    maps the ADB interface class (ff4201) to ID_DEBUG_APPLIANCE and then
      #    to TAG+="uaccess" on its own.
      if [ -z "$TARGET" ]; then
        SER="$(usb_serial)"
        if [ -z "$SER" ]; then
          notify "Boox not reachable" \
            "Plug the tablet in once with a cable that carries DATA, then launch again."
          echo "No BOOX on the network and none on USB." >&2
          echo "A charge-only cable logs NOTHING in the kernel - that is the tell." >&2
          exit 1
        fi
        NEWIP="$(adb -s "$SER" shell ip -f inet addr show wlan0 2>/dev/null \
                 | awk '/inet /{print $2}' | cut -d/ -f1 | tr -d '\r')"
        if [ -n "$NEWIP" ]; then IP="$NEWIP"; fi
        if [ -z "$IP" ]; then
          notify "Boox" "Connected by USB, but could not read the tablet's Wi-Fi address."
          exit 1
        fi
        adb -s "$SER" tcpip "$PORT" >/dev/null 2>&1
        sleep 2
        adb connect "$IP:$PORT" >/dev/null 2>&1
        TARGET="$(net_target)"
      fi

      if [ -z "$TARGET" ] || ! alive "$TARGET"; then
        notify "Boox not reachable" "Wake the tablet and launch again."
        exit 1
      fi
      printf '%s\n' "''${TARGET%%:*}" > "$IP_FILE"

      ORIENT_ARGS=()
      if [ -n "''${BOOX_ORIENTATION:-}" ]; then
        ORIENT_ARGS=(--display-orientation="''${BOOX_ORIENTATION}")
      fi

      # THE SLEEP PROBLEM. screen_off_timeout was 300000 ms (5 min). On sleep the
      # radio drops TCP, the adb transport goes "offline" - NOT gone, the tablet
      # still pings at 0% loss - and scrcpy exits 2 with "Device disconnected".
      # Raised on the device to 1800000 (30 min), which on e-ink is nearly free:
      # the panel draws power to CHANGE an image, not to HOLD one.
      #     adb -s <target> shell settings put system screen_off_timeout 1800000
      #
      # Retry ONLY on exit 2. Exit 0 is the window being closed, so this never
      # fights the user by respawning. Verified by forcing a real drop: back in
      # about 4 seconds.
      fails=0
      while :; do
        scrcpy -s "$TARGET" \
          --no-control --no-audio \
          --video-codec=h264 \
          --max-size="$MAXSIZE" \
          "''${ORIENT_ARGS[@]}" \
          --window-title="$TITLE"
        rc=$?

        if [ "$rc" -ne 2 ]; then exit "$rc"; fi

        notify "Boox disconnected" "Tablet asleep? Tap it - reconnecting automatically."
        while :; do
          adb disconnect "$TARGET" >/dev/null 2>&1
          adb connect "$TARGET" >/dev/null 2>&1
          if alive "$TARGET"; then fails=0; break; fi
          fails=$((fails + 1))
          if [ "$fails" -ge "$MAX_FAILS" ]; then
            notify "Boox gave up" "No reconnect after about $((fails * RETRY_DELAY))s."
            exit 1
          fi
          sleep "$RETRY_DELAY"
        done
      done
    '';
  };
in
{
  home.packages = [ boox ];

  xdg.dataFile."icons/hicolor/scalable/apps/boox.svg".source = booxIcon;

  # Written through xdg.dataFile, NOT xdg.desktopEntries, and that is
  # deliberate. `xdg.enable` is false on this machine, and with it off
  # home-manager emits NO .desktop files at all: the built home-manager-files
  # package contains zero of them, including the long-standing
  # `xdg.desktopEntries.discord` in packages.nix, which has therefore been
  # silently inert (Discord appears in the menu because its own PACKAGE ships
  # an entry, not because of that block). `xdg.dataFile` is unaffected by the
  # same flag -- verified in the same build, where the icon above landed at
  # .local/share/icons/hicolor/scalable/apps/boox.svg.
  #
  # Flipping xdg.enable = true would fix desktopEntries, but it also hands
  # home-manager the user-dirs and mime configuration, which is a much larger
  # change than installing one launcher. Not worth it for this.
  #
  # StartupWMClass: scrcpy sets WM_CLASS=scrcpy, so without it GNOME shows a
  # generic icon in the dash for the running window instead of this one.
  xdg.dataFile."applications/boox.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Boox
    GenericName=E-ink tablet mirror
    Comment=Draw on the BOOX Note Air 3 C and mirror it here over Wi-Fi
    Exec=boox
    Icon=boox
    Terminal=false
    Categories=Utility;
    StartupWMClass=scrcpy
  '';
}
