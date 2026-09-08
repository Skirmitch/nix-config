{ pkgs, ... }:
let
  # One script owns mode selection, so the probes the timer acts on are
  # literally the ones `status` prints and they cannot drift apart.
  remoteDesktopMode = pkgs.writeShellApplication {
    name = "remote-desktop-mode";
    runtimeInputs = with pkgs; [ systemd coreutils gnugrep iproute2 ];
    text = ''
      # Flip between the two RDP modes. The units Conflict= with each other,
      # so starting one stops the other; both listen on 3389.
      #
      #   headless  virtual monitor, works with the screens switched OFF
      #   mirror    shows the real desktop, REQUIRES a connected monitor
      #   auto      hand it back to the timer (the default after every login)
      #
      # `tick` is what the timer calls; it is not meant to be typed.

      STATE="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/remote-desktop-mode"
      PIN="$STATE.pin"           # manual override: "<mode> <expiry-epoch>"
      DEAD="$STATE.deadmirror"   # consecutive ticks seeing a doomed mirror
      DEFER="$STATE.deferred"    # marker: this deferral was already logged
      PIN_TTL=$((8 * 3600))
      PIN_HOURS=$((PIN_TTL / 3600))

      # say/err are for a terminal. note() is for the journal: the timer's
      # unit runs with LogLevelMax=warning so 2,880 no-op ticks a day leave
      # no trace, and the <4> (warning) prefix is what lets a line through.
      say()  { if [ -t 1 ]; then printf '\033[1;32m[remote-desktop]\033[0m %s\n' "$*"; else printf '[remote-desktop] %s\n' "$*"; fi; }
      err()  { if [ -t 2 ]; then printf '\033[1;31m[remote-desktop]\033[0m %s\n' "$*" >&2; else printf '[remote-desktop] %s\n' "$*" >&2; fi; }
      note() { if [ -t 1 ]; then say "$*"; else printf '<4>[remote-desktop] %s\n' "$*"; fi; }

      # Exactly `connected`, and nothing else:
      #   - card1-Writeback-1 reads `unknown` forever (writeback connector,
      #     not a panel), so anything looser pins mirror permanently;
      #   - do NOT also require enabled=enabled. GNOME idle-blanking drops the
      #     CRTC, so a screen that is physically ON reads `disabled` - gating
      #     on it would flip to headless and hand the phone the empty extended
      #     desktop, which is the bug this whole file exists to fix.
      #   - never ask Mutter: in headless mode the virtual monitor g-r-d
      #     creates shows up in Mutter's own monitor list, so an arbiter fed
      #     from there sees its own output and oscillates.
      # The card*-* glob is deliberate: card numbering is not stable.
      monitors_present() {
        grep -qx connected /sys/class/drm/card*-*/status 2>/dev/null
      }

      # ss exits 0 with EMPTY output when nobody is connected, so test the
      # text. If ss itself fails, assume a client IS connected: a wrong "no
      # peer" cuts a live session, a wrong "peer" only defers the switch.
      peer_established() {
        local out
        if ! out="$(ss -Htn state established '( sport = :3389 )')"; then
          note "ss failed; assuming a client is connected"
          return 0
        fi
        [ -n "$out" ]
      }

      # `activating` counts: both units are Type=dbus and take 1-3s to claim
      # their bus name, and a tick landing in that window must not read the
      # world as "nothing running".
      unit_up() {
        case "$(systemctl --user show -p ActiveState --value "$1")" in
          active|activating|reloading) return 0 ;;
          *) return 1 ;;
        esac
      }
      active_mode() {
        if unit_up gnome-remote-desktop-headless.service; then
          echo headless
        elif unit_up gnome-remote-desktop.service; then
          echo mirror
        else
          echo none
        fi
      }

      read_pin() {
        local mode deadline
        [ -s "$PIN" ] || return 0
        read -r mode deadline < "$PIN" || [ -n "$deadline" ] || return 0
        case "$mode" in headless|mirror) ;; *) rm -f "$PIN"; return 0 ;; esac
        case "$deadline" in ""|*[!0-9]*) rm -f "$PIN"; return 0 ;; esac
        if [ "$(date +%s)" -ge "$deadline" ]; then rm -f "$PIN"; return 0; fi
        # A headless pin is sticky: headless always works. A mirror pin is
        # only as good as its premise - with the screens off it would strand
        # the phone on the one mode that cannot work, i.e. the ago-10 outage.
        if [ "$mode" = mirror ] && ! monitors_present; then rm -f "$PIN"; return 0; fi
        printf '%s' "$mode"
      }

      write_pin() { printf '%s %s\n' "$1" "$(( $(date +%s) + PIN_TTL ))" > "$PIN"; }

      # Conflicts= gives exclusion, not ordering: systemd may exec the
      # incoming daemon before the outgoing one has closed :3389, and a bind
      # failure does not make a Type=dbus unit exit - it would sit "active"
      # with nothing listening. So stop the other side first (blocking), then
      # start ours. The ~200ms with no listener is unavoidable (the daemon
      # re-inits its encoder) and shows up as one failed connect if the phone
      # happens to dial exactly then.
      # $2 is passed to the start: tick uses --no-block because it runs inside
      # the login transaction; typed commands block so a failed start shows.
      start_mode() {
        local unit other
        case "$1" in
          headless) unit=gnome-remote-desktop-headless.service; other=gnome-remote-desktop.service ;;
          mirror)   unit=gnome-remote-desktop.service; other=gnome-remote-desktop-headless.service ;;
          *) err "unknown mode: $1"; return 1 ;;
        esac
        systemctl --user stop "$other"
        systemctl --user "''${@:2}" start "$unit"
      }

      # NOTE: `return`, never `exit` - `auto` calls tick and then prints.
      tick() {
        local want have n
        # `activating` too: at login this runs while the target is still
        # being reached, and that first run is the one that matters.
        case "$(systemctl --user show -p ActiveState --value gnome-session.target)" in
          active|activating) ;;
          *) return 0 ;;
        esac

        want="$(read_pin)"
        if [ -z "$want" ]; then
          if monitors_present; then want=mirror; else want=headless; fi
        fi
        have="$(active_mode)"
        if [ "$want" = "$have" ]; then rm -f "$DEAD" "$DEFER"; return 0; fi

        # Conflicts= teardown reaches the client as
        # ERRINFO_RPC_INITIATED_DISCONNECT, so never cut a working session.
        # The one exception: a mirror session with zero connectors is already
        # dead (it dies per-connection with "Unknown monitor"). Debounced over
        # two ticks, because a GPU reset can make every connector read
        # `disconnected` for a moment and that lie must not kill a live peer.
        if peer_established; then
          if [ "$have" = mirror ] && [ "$want" = headless ]; then
            n="$(cat "$DEAD" 2>/dev/null || true)"
            case "$n" in ""|*[!0-9]*) n=0 ;; esac
            n=$((n + 1))
            printf '%s\n' "$n" > "$DEAD"
            if [ "$n" -lt 2 ]; then
              note "client connected; mirror looks dead ($n/2) before switching to headless"
              return 0
            fi
          else
            rm -f "$DEAD"
            # Once per episode, not twice a minute for the length of a call.
            if [ ! -e "$DEFER" ]; then
              note "client connected; deferring $have -> $want until it disconnects"
              : > "$DEFER"
            fi
            return 0
          fi
        fi
        rm -f "$DEAD" "$DEFER"
        note "autoselect: $have -> $want"
        start_mode "$want" "$@"
      }

      case "''${1:-status}" in
        auto)
          rm -f "$PIN" "$DEAD" "$DEFER"
          tick
          say "Automatic: mirror while a screen is on, headless when they are off."
          ;;
        headless)
          rm -f "$DEAD" "$DEFER"
          write_pin headless
          start_mode headless
          say "Pinned to headless for ''${PIN_HOURS}h (or until you log out). A"
          say "virtual monitor is created on connect; the screens can stay off."
          say "'remote-desktop-mode auto' releases the pin."
          ;;
        mirror)
          if ! monitors_present; then
            err "No connected monitor. Mirror mode would authenticate you and"
            err "then drop the session with 'Unknown monitor'. Refusing."
            err "Switch a screen on first, or stay on headless."
            exit 1
          fi
          rm -f "$DEAD" "$DEFER"
          write_pin mirror
          start_mode mirror
          say "Pinned to mirror for ''${PIN_HOURS}h (or until you log out); the"
          say "pin self-voids when the screens go off."
          ;;
        tick)
          tick --no-block
          ;;
        status)
          case "$(active_mode)" in
            headless) echo "Mode     : headless (virtual monitor)" ;;
            mirror)   echo "Mode     : mirror (physical desktop)" ;;
            *)        echo "Mode     : none (neither service is running)" ;;
          esac
          if monitors_present; then
            echo "Monitors : at least one connected"
          else
            echo "Monitors : none connected (mirror mode would fail)"
          fi
          pin="$(read_pin)"
          if [ -n "$pin" ]; then
            echo "Pin      : $pin (until $(date -d "@$(cut -d' ' -f2 "$PIN")" '+%H:%M'))"
          else
            echo "Pin      : none (automatic)"
          fi
          if peer_established; then
            echo "Client   : connected (mode changes are deferred)"
          else
            echo "Client   : none"
          fi
          ;;
        *)
          echo "Usage: remote-desktop-mode {auto|headless|mirror|status}" >&2
          exit 1
          ;;
      esac
    '';
  };
in {
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
  #   grdctl --headless -> creates a *virtual* monitor
  #   grdctl --system   -> remote login at GDM (no session yet)
  #
  # THE MODE IS PICKED AUTOMATICALLY: mirror while any DP/HDMI connector reads
  # `connected`, headless otherwise, re-checked every 30s and never switched
  # out from under a connected client. `remote-desktop-mode {mirror,headless}`
  # pins it for 8h (or until logout); `auto` hands it back.
  #
  # WHY MIRROR CANNOT BE THE ONLY MODE. Desktop sharing needs a physical
  # monitor to mirror; with the screens switched off the DP/HDMI connectors go
  # `disconnected`, Mutter reports zero monitors, and every connection dies at
  # "Failed to record monitor: ... Unknown monitor" *after* authenticating -
  # so it looks like a broken password, not a missing display. Diagnosed
  # 2026-08-10 from Miami: the monitors are routinely off so Pepa (the parrot)
  # can sleep, which makes this the normal case, not an edge case. Headless
  # conjures a 2560x1440 virtual monitor on connect and does not care whether
  # anything is plugged in.
  #
  # WHY HEADLESS CANNOT BE THE ONLY MODE. With a physical monitor on, that
  # virtual monitor is added as an EXTENSION of the desktop, so the phone shows
  # an empty screen instead of the one on the desk (2026-09-07). Headless does
  # attach to the EXISTING session (no second session is spawned), so open
  # apps are still there - just not on the monitor the phone is looking at.
  #
  # Reachability comes from ../system/tailscale.nix; port 3389 is never open
  # on the LAN or the WAN.
  #
  # Runtime setup is deliberately NOT declarative: the RDP password is stored
  # in the GNOME login keyring and the TLS keypair is per-machine. Run
  # `remote-desktop-setup` once (it is idempotent). Both live under paths
  # persisted in hosts/diana/impermanence.nix.

  services.gnome.gnome-remote-desktop.enable = true;

  # The user daemons are Type=dbus but nothing calls their bus names on its
  # own, so a unit has to be explicitly wanted or it never starts. Their
  # [Install] sections say exactly this, but NixOS pulls the units in via
  # systemd.packages and ignores [Install] sections - hence the restatement.
  #
  # Keep it declarative, and never `systemctl --user enable` these: that links
  # the unit file into ~/.config/systemd/user (which DOES persist - /home is
  # its own never-wiped subvol), where it shadows /etc and pins the daemon to
  # whatever store path was current that day. Found 2026-09-07: both units
  # wanted from ~/.config (the Conflicts= race below) and running the 50.1
  # binary on a 50.2 system. Note `grdctl rdp enable` also calls
  # EnableUnitFiles on the session bus, so re-check ~/.config after running it.
  #
  # HEADLESS IS THE FLOOR, not the policy. It is the mode that always works,
  # so it is the one thing wanted at login; the selector below may upgrade to
  # mirror a second later. If the selector breaks, RDP degrades to "always
  # headless" - the old behaviour - instead of to nothing, which is the right
  # failure when you are debugging from another continent. Mirror is never
  # wanted directly: the units Conflicts= on each other, so wanting both would
  # race and leave the winner to chance.
  systemd.user.services.gnome-remote-desktop-headless.wantedBy = [ "gnome-session.target" ];

  # Mode selection is a POLL, not a watch, and that is deliberate. The mirror
  # unit does NOT fail when there is no monitor: it starts, stays active, and
  # fails per-connection at record time ("Failed to record monitor: Unknown
  # monitor"), so Restart=on-failure never fires and being 30s late costs
  # nothing. A udev route needs SYSTEMD_READY + a PROGRAM= helper whose truth
  # branch udevadm test refuses to execute; inotify on sysfs never fires; a
  # Mutter DisplayConfig watcher needs a long-running process with reconnect
  # logic - and Mutter is unusable as the signal anyway (see monitors_present).
  # A timer also heals two things no event source can: gnome-session.target
  # Wants= the headless unit but does NOT After= it (so its login start job can
  # kill a just-started mirror), and a switch deferred because a client is
  # connected needs a retry.
  systemd.user.services.remote-desktop-autoselect = {
    description = "Pick the RDP mode that matches the physical monitors";
    # After the floor, so the upgrade happens on top of a session that is
    # already reachable. Both g-r-d units are Type=dbus, so After= waits for
    # the bus name. Deliberately NOT after gnome-session.target: at login this
    # runs while the target is still `activating`, and the script accepts that.
    after = [ "gnome-remote-desktop-headless.service" ];
    wantedBy = [ "gnome-session.target" ];
    # /etc/systemd/user is shared with every user manager on the box, and the
    # gdm greeter (uid 60578, group gdm - NOT a system uid) reaches
    # gnome-session.target too. Neither condition hardcodes a username.
    unitConfig = {
      ConditionUser = "!@system";
      ConditionGroup = "!gdm";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${remoteDesktopMode}/bin/remote-desktop-mode tick";
      # 2,880 runs a day; drop the Starting/Finished pair and the no-op
      # chatter. The script prefixes the lines that matter with <4>.
      LogLevelMax = "warning";
    };
  };

  systemd.user.timers.remote-desktop-autoselect = {
    description = "Re-check the physical monitors every 30s";
    # timers.target as well: `nixos-rebuild switch` restarts that (active,
    # not RefuseManualStart) and thereby starts a NEW timer in the live
    # session; gnome-session.target alone would leave it dormant until the
    # next login. Early fires before the session is up are no-ops.
    wantedBy = [ "gnome-session.target" "timers.target" ];
    partOf = [ "graphical-session.target" ];
    unitConfig = {
      ConditionUser = "!@system";
      ConditionGroup = "!gdm";
    };
    timerConfig = {
      OnActiveSec = "15s";        # anchor that works even if the service never ran
      OnUnitInactiveSec = "30s";  # measured from tick completion (~7ms)
      AccuracySec = "5s";         # the default 1min fudge would make 30s meaningless
    };
  };

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "remote-desktop-setup";
      runtimeInputs = with pkgs; [ gnome-remote-desktop openssl coreutils gnused gnugrep systemd ];
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

        # `rdp enable` also calls EnableUnitFiles on the session bus: it links
        # both unit files into ~/.config/systemd/user (which persists) and
        # wants BOTH from gnome-session.target - the Conflicts= race, plus the
        # daemon pinned to today's store path (found 2026-09-07: running 50.1
        # on a 50.2 system, from the Aug 7 + Aug 10 runs of this script).
        # Auto-start is declarative (systemd.user.services below); undo it.
        systemctl --user disable gnome-remote-desktop.service gnome-remote-desktop-headless.service >/dev/null 2>&1 || true
        rm -f "$HOME"/.config/systemd/user/gnome-remote-desktop{,-headless}.service \
              "$HOME"/.config/systemd/user/gnome-session.target.wants/gnome-remote-desktop{,-headless}.service
        rmdir "$HOME"/.config/systemd/user/gnome-session.target.wants 2>/dev/null || true
        systemctl --user daemon-reload

        # Auto-start is declarative (systemd.user.services above); this only
        # brings the RIGHT mode up now so you don't have to log out to test.
        ${remoteDesktopMode}/bin/remote-desktop-mode auto

        msg "Done. Status:"
        ${remoteDesktopMode}/bin/remote-desktop-mode status
      '';
    })

    remoteDesktopMode
  ];
}
