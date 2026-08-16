{ pkgs, ... }: {
  # --- GNOME Remote Desktop: phone -> Diana's live session over RDP ---
  #
  # Why this and not TeamViewer/AnyDesk: this host runs a GNOME 50 *Wayland*
  # session, and GNOME 50's Mutter has no X11 backend left. TeamViewer's Linux
  # client still requires Xorg for *incoming* control (Wayland gets outgoing
  # control, plus "attended" access needing someone to approve at the keyboard
  # — useless when you are the one holding the phone). gnome-remote-desktop is
  # Mutter's own code path: real Wayland screen capture via PipeWire and real
  # input injection, no screen-scraping shim.
  #
  # Three modes exist:
  #
  #   grdctl            -> desktop sharing: mirrors a *physical* monitor
  #   grdctl --headless -> creates a *virtual* monitor            <-- ours
  #   grdctl --system   -> remote login at GDM (no session yet)
  #
  # HEADLESS IS THE DEFAULT HERE, and the reason is not obvious. Desktop
  # sharing needs a physical monitor to mirror; with the screens switched off
  # the DP/HDMI connectors go `disconnected`, Mutter reports zero monitors, and
  # every connection dies at "Failed to record monitor: ... Unknown monitor"
  # *after* authenticating — so it looks like a broken password, not a missing
  # display. Diagnosed 2026-08-10 from Miami: the monitors are routinely off so
  # Pepa (the parrot) can sleep, which makes this the normal case, not an edge
  # case. Headless conjures a 2560x1440 virtual monitor on connect and does not
  # care whether anything is plugged in.
  #
  # Verified: headless attaches the virtual monitor to the EXISTING session
  # (no second session is spawned), so open apps are still there.
  #
  # `remote-desktop-mode mirror` flips back to true screen-mirroring when the
  # monitors are on and you want to see the actual desktop.
  #
  # Reachability comes from ../system/tailscale.nix; port 3389 is never open
  # on the LAN or the WAN.
  #
  # Runtime setup is deliberately NOT declarative: the RDP password is stored
  # in the GNOME login keyring and the TLS keypair is per-machine. Run
  # `remote-desktop-setup` once (it is idempotent). Both live under paths
  # persisted in hosts/diana/impermanence.nix.

  services.gnome.gnome-remote-desktop.enable = true;

  # The user daemon is Type=dbus but nothing calls org.gnome.RemoteDesktop.User
  # on its own, so it has to be explicitly wanted or it never starts. Its
  # [Install] section says exactly this, but NixOS pulls the unit in via
  # systemd.packages and ignores [Install] sections — hence the restatement.
  #
  # This MUST stay declarative. Doing it with `systemctl --user enable` writes
  # a symlink into ~/.config/systemd/user, which is not persisted on this
  # impermanent host: it would work until the next reboot and then quietly
  # stop auto-starting — discovered from somewhere with no keyboard.
  # Only the HEADLESS unit is wanted. The two units declare Conflicts= on each
  # other, so wanting both would race at login and leave the winner to chance.
  systemd.user.services.gnome-remote-desktop-headless.wantedBy = [ "gnome-session.target" ];

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "remote-desktop-setup";
      runtimeInputs = with pkgs; [ gnome-remote-desktop openssl coreutils systemd gnugrep ];
      text = ''
        CERT_DIR="$HOME/.local/share/gnome-remote-desktop/certificates"
        CERT="$CERT_DIR/rdp-tls.crt"
        KEY="$CERT_DIR/rdp-tls.key"

        msg() { printf '\033[1;32m[remote-desktop]\033[0m %s\n' "$*"; }

        # grdctl validates the *currently configured* certificate on every
        # startup, so on a first run — before any cert is set — it prints a
        # FreeRDP x509 error that looks like a failure but is not. Filter that
        # one message only; any other output, and any non-zero exit, still
        # surfaces normally.
        quiet_grdctl() {
          local out
          if ! out="$(grdctl "$@" 2>&1)"; then
            printf '%s\n' "$out" >&2
            return 1
          fi
          printf '%s' "$out" \
            | grep -v -e 'x509_utils_from_pem' -e 'RDP server certificate is invalid' \
            || true
        }

        # gnome-remote-desktop ships no certificate and refuses to start
        # without one. Self-signed is fine: the client pins it on first
        # connect, and only tailnet peers can reach the port at all.
        if [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; then
          msg "Generating a self-signed RDP TLS certificate (10 years)..."
          mkdir -p "$CERT_DIR"
          openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
            -subj "/C=CL/ST=RM/L=Santiago/O=Diana/CN=diana" \
            -out "$CERT" -keyout "$KEY" 2>/dev/null
          chmod 600 "$KEY"
        else
          msg "Existing certificate found - keeping it."
        fi

        # Configure BOTH modes identically. They keep separate credential
        # stores, so configuring only one means `remote-desktop-mode` flips you
        # into a mode that rejects your password — which is exactly the kind of
        # thing you discover from another continent.
        for mode in "" "--headless"; do
          # shellcheck disable=SC2086 # intentional: empty = desktop-sharing mode
          quiet_grdctl $mode rdp set-tls-cert "$CERT"
          # shellcheck disable=SC2086
          quiet_grdctl $mode rdp set-tls-key  "$KEY"
        done

        if [ $# -ge 2 ]; then
          rdp_user="$1"; rdp_pass="$2"
        elif ! grdctl status --show-credentials 2>/dev/null | grep -q "Username: [^(]"; then
          read -rp  "  RDP username: " rdp_user
          read -rsp "  RDP password: " rdp_pass; echo
        else
          msg "Credentials already stored - reusing them for both modes."
          rdp_user="$(grdctl status --show-credentials 2>/dev/null | sed -n 's/^[[:space:]]*Username: //p')"
          rdp_pass="$(grdctl status --show-credentials 2>/dev/null | sed -n 's/^[[:space:]]*Password: //p')"
        fi
        quiet_grdctl rdp            set-credentials "$rdp_user" "$rdp_pass"
        quiet_grdctl --headless rdp set-credentials "$rdp_user" "$rdp_pass"

        # Desktop-sharing defaults to view-only, which looks identical to a
        # working setup until you try to move the mouse. This is the line that
        # grants control. (Headless has no view-only concept.)
        quiet_grdctl rdp disable-view-only
        quiet_grdctl rdp enable
        quiet_grdctl --headless rdp enable

        # Auto-start is declarative (systemd.user.services above); this only
        # brings the default mode up now so you don't have to log out to test.
        systemctl --user start gnome-remote-desktop-headless.service

        msg "Done. Status (headless / default mode):"
        quiet_grdctl --headless status
      '';
    })

    (pkgs.writeShellApplication {
      name = "remote-desktop-mode";
      runtimeInputs = with pkgs; [ gnome-remote-desktop systemd coreutils gnugrep ];
      text = ''
        # Flip between the two RDP modes. The units Conflict= with each other,
        # so starting one stops the other; both listen on 3389.
        #
        #   headless  virtual monitor, works with the screens switched OFF
        #   mirror    shows the real desktop, REQUIRES a connected monitor
        #
        # Runtime only — a reboot returns to the declarative default (headless).

        msg() { printf '\033[1;32m[remote-desktop]\033[0m %s\n' "$*"; }
        err() { printf '\033[1;31m[remote-desktop]\033[0m %s\n' "$*" >&2; }

        monitors_present() {
          grep -qx connected /sys/class/drm/card*-*/status 2>/dev/null
        }

        case "''${1:-status}" in
          headless)
            systemctl --user start gnome-remote-desktop-headless.service
            msg "Headless. A virtual monitor is created on connect; the"
            msg "physical screens can stay off."
            ;;
          mirror)
            if ! monitors_present; then
              err "No connected monitor. Mirror mode would authenticate you and"
              err "then drop the session with 'Unknown monitor'. Refusing."
              err "Switch a screen on first, or stay on headless."
              exit 1
            fi
            systemctl --user start gnome-remote-desktop.service
            msg "Mirroring the physical desktop."
            ;;
          status)
            if systemctl --user is-active --quiet gnome-remote-desktop-headless.service; then
              echo "Mode     : headless (virtual monitor)"
            elif systemctl --user is-active --quiet gnome-remote-desktop.service; then
              echo "Mode     : mirror (physical desktop)"
            else
              echo "Mode     : neither service is running"
            fi
            if monitors_present; then
              echo "Monitors : at least one connected"
            else
              echo "Monitors : none connected (mirror mode would fail)"
            fi
            ;;
          *)
            echo "Usage: remote-desktop-mode {headless|mirror|status}" >&2
            exit 1
            ;;
        esac
      '';
    })
  ];
}
