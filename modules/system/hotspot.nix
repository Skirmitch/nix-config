{ pkgs, ... }:

# Plain (non-VPN) Wi-Fi hotspot for the Diana host.
#
#   hotspot up      Start the 5 GHz "Diana" hotspot, sharing the normal
#                   (non-VPN) internet via NetworkManager's NAT.
#   hotspot down    Stop it; the Wi-Fi adapter rejoins normal Wi-Fi.
#   hotspot status  Show current state.
#
# Same Wi-Fi adapter as vpn-hotspot, so only one of the two runs at a time.
# On first `up` it creates the NetworkManager profile and prompts once for a
# Wi-Fi password (stored in /etc/NetworkManager, never in this repo).

let
  hotspot = pkgs.writeShellApplication {
    name = "hotspot";
    runtimeInputs = with pkgs; [
      networkmanager
      iptables
      iproute2
      iw
      coreutils
      gnugrep
      gawk
    ];
    text = ''
      # --- settings -----------------------------------------------------
      HS_PROFILE="Diana"            # NetworkManager connection name
      HS_SSID="Diana"               # broadcast network name
      HS_IFACE="wlp12s0u1i3"        # USB Wi-Fi adapter used as the AP
      HS_CHANNEL="36"               # 5 GHz channel (36 = non-DFS, global)
      REGDOMAIN="CL"                # wireless regulatory domain (5 GHz AP)
      VPN_CHAIN="VPN-HOTSPOT"       # vpn-hotspot's iptables chain, to clear

      msg() { printf '\033[1;32m[hotspot]\033[0m %s\n' "$*"; }
      err() { printf '\033[1;31m[hotspot]\033[0m %s\n' "$*" >&2; }

      need_root() {
        if [ "$(id -u)" -ne 0 ]; then
          exec /run/wrappers/bin/sudo "$0" "$@"
        fi
      }

      # Remove vpn-hotspot's kill-switch chain if present - otherwise its
      # REJECT rule would block this plain hotspot's clients.
      fw_clear() {
        iptables        -D FORWARD     -j "$VPN_CHAIN" 2>/dev/null || true
        iptables        -F "$VPN_CHAIN"                2>/dev/null || true
        iptables        -X "$VPN_CHAIN"                2>/dev/null || true
        iptables -t nat -D POSTROUTING -j "$VPN_CHAIN" 2>/dev/null || true
        iptables -t nat -F "$VPN_CHAIN"                2>/dev/null || true
        iptables -t nat -X "$VPN_CHAIN"                2>/dev/null || true
      }

      do_up() {
        msg "Applying regulatory domain $REGDOMAIN (needed for 5 GHz)..."
        iw reg set "$REGDOMAIN" 2>/dev/null || true
        sleep 1

        if ! nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$HS_PROFILE"; then
          msg "First run - creating the '$HS_SSID' hotspot profile."
          local psk=""
          while :; do
            read -rsp "  Wi-Fi password for '$HS_SSID' (8+ chars): " psk || { echo; err "Cancelled."; exit 1; }
            echo
            if [ "''${#psk}" -ge 8 ]; then break; fi
            err "Too short - WPA2 needs at least 8 characters."
          done
          if ! nmcli connection add type wifi ifname "$HS_IFACE" con-name "$HS_PROFILE" \
                 autoconnect no ssid "$HS_SSID" \
                 802-11-wireless.mode ap \
                 802-11-wireless.band a 802-11-wireless.channel "$HS_CHANNEL" \
                 wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$psk" \
                 wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp \
                 ipv4.method shared ipv6.method ignore >/dev/null; then
            err "Failed to create the NetworkManager profile."
            exit 1
          fi
          msg "Profile '$HS_PROFILE' created."
        fi

        msg "Setting $HS_PROFILE to 5 GHz (channel $HS_CHANNEL)..."
        nmcli connection modify "$HS_PROFILE" \
          802-11-wireless.band a \
          802-11-wireless.channel "$HS_CHANNEL"

        fw_clear   # drop vpn-hotspot's kill-switch if it was left active

        msg "Starting hotspot on $HS_IFACE..."
        if ! nmcli connection up "$HS_PROFILE"; then
          err "Hotspot failed to start."
          exit 1
        fi
        msg "Up. SSID '$HS_SSID' is broadcasting - clients get normal, non-VPN internet."
      }

      do_down() {
        msg "Stopping hotspot..."
        nmcli connection down "$HS_PROFILE" 2>/dev/null || true
        msg "Down. $HS_IFACE will rejoin your normal Wi-Fi."
      }

      do_status() {
        if nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$HS_PROFILE"; then
          local addr
          addr="$(ip -4 -o addr show "$HS_IFACE" 2>/dev/null | awk 'NR==1{print $4}')" || true
          echo "Hotspot : up - SSID '$HS_SSID' (''${addr:-?} on $HS_IFACE)"
        else
          echo "Hotspot : down"
        fi
      }

      case "''${1:-}" in
        up)     need_root "$@"; do_up ;;
        down)   need_root "$@"; do_down ;;
        status) do_status ;;
        *)      echo "Usage: hotspot {up|down|status}" >&2; exit 1 ;;
      esac
    '';
  };
in
{
  environment.systemPackages = [ hotspot ];
}
