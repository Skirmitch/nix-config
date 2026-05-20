{ pkgs, ... }:

# On-demand NordVPN hotspot for the Diana host.
#
#   vpn-hotspot up      Connect NordVPN (US) + start the 5 GHz "DianaVPN"
#                       hotspot, routing every client through the tunnel.
#   vpn-hotspot down    Tear it down; the Wi-Fi adapter rejoins normal Wi-Fi.
#   vpn-hotspot status  Show current state.
#
# Strict kill-switch: if the tunnel drops, hotspot clients lose internet
# instead of leaking onto the normal (non-VPN) connection.
#
# Relies on the existing wgnord login (/var/lib/wgnord) and the existing
# NetworkManager "Hotspot" profile (SSID DianaVPN, ipv4.method=shared).

let
  vpn-hotspot = pkgs.writeShellApplication {
    name = "vpn-hotspot";
    runtimeInputs = with pkgs; [
      wgnord
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
      WG_IFACE="wgnord"             # interface created by wgnord / wg-quick
      HS_PROFILE="Hotspot"          # NetworkManager connection name
      HS_IFACE="wlp12s0u1i3"        # USB Wi-Fi adapter used as the AP
      VPN_COUNTRY="United States"   # NordVPN country (wgnord country name)
      HS_CHANNEL="36"               # 5 GHz channel (36 = non-DFS, global)
      REGDOMAIN="CL"                # wireless regulatory domain (5 GHz AP)
      CHAIN="VPN-HOTSPOT"           # our dedicated iptables chain

      msg() { printf '\033[1;32m[vpn-hotspot]\033[0m %s\n' "$*"; }
      err() { printf '\033[1;31m[vpn-hotspot]\033[0m %s\n' "$*" >&2; }

      need_root() {
        if [ "$(id -u)" -ne 0 ]; then
          exec /run/wrappers/bin/sudo "$0" "$@"
        fi
      }

      # Drop our chains and jumps from the filter and nat tables.
      fw_clear() {
        iptables        -D FORWARD     -j "$CHAIN" 2>/dev/null || true
        iptables        -F "$CHAIN"                2>/dev/null || true
        iptables        -X "$CHAIN"                2>/dev/null || true
        iptables -t nat -D POSTROUTING -j "$CHAIN" 2>/dev/null || true
        iptables -t nat -F "$CHAIN"                2>/dev/null || true
        iptables -t nat -X "$CHAIN"                2>/dev/null || true
      }

      # Permit hotspot <-> VPN forwarding, reject any other egress from the
      # hotspot (the kill-switch), and masquerade the hotspot subnet onto the
      # tunnel. Jumped in at position 1 so it is evaluated before Docker's
      # rules and the default FORWARD policy.
      fw_apply() {
        local subnet="$1"
        fw_clear
        iptables -N "$CHAIN" 2>/dev/null || true
        iptables -A "$CHAIN" -i "$HS_IFACE" -o "$WG_IFACE" -j ACCEPT
        iptables -A "$CHAIN" -i "$WG_IFACE" -o "$HS_IFACE" -j ACCEPT
        iptables -A "$CHAIN" -i "$HS_IFACE" "!" -o "$WG_IFACE" -j REJECT
        iptables -I FORWARD 1 -j "$CHAIN"
        iptables -t nat -N "$CHAIN" 2>/dev/null || true
        iptables -t nat -A "$CHAIN" -s "$subnet" -o "$WG_IFACE" -j MASQUERADE
        iptables -t nat -I POSTROUTING 1 -j "$CHAIN"
      }

      do_up() {
        msg "Connecting NordVPN ($VPN_COUNTRY)..."
        if ! wgnord c "$VPN_COUNTRY"; then
          err "NordVPN connection failed - aborting."
          exit 1
        fi
        if ! ip link show "$WG_IFACE" >/dev/null 2>&1; then
          err "VPN interface $WG_IFACE never appeared - aborting."
          exit 1
        fi

        msg "Applying regulatory domain $REGDOMAIN (needed for 5 GHz)..."
        iw reg set "$REGDOMAIN" 2>/dev/null || true
        sleep 1

        msg "Setting $HS_PROFILE to 5 GHz (channel $HS_CHANNEL)..."
        nmcli connection modify "$HS_PROFILE" \
          802-11-wireless.band a \
          802-11-wireless.channel "$HS_CHANNEL"

        msg "Starting hotspot on $HS_IFACE..."
        if ! nmcli connection up "$HS_PROFILE"; then
          err "Hotspot failed to start - disconnecting VPN."
          wgnord d 2>/dev/null || true
          exit 1
        fi

        local subnet="" n
        for (( n = 0; n < 20; n++ )); do
          subnet="$(ip -4 route show dev "$HS_IFACE" scope link proto kernel 2>/dev/null | awk 'NR==1{print $1}')" || true
          [ -n "$subnet" ] && break
          sleep 0.5
        done
        if [ -z "$subnet" ]; then
          err "Could not determine the hotspot subnet - rolling back."
          nmcli connection down "$HS_PROFILE" 2>/dev/null || true
          wgnord d 2>/dev/null || true
          exit 1
        fi

        msg "Routing $subnet through $WG_IFACE (kill-switch on)..."
        fw_apply "$subnet"
        msg "Up. Clients on $subnet now reach the internet only via NordVPN."
      }

      do_down() {
        msg "Removing VPN routing rules..."
        fw_clear
        msg "Stopping hotspot..."
        nmcli connection down "$HS_PROFILE" 2>/dev/null || true
        msg "Disconnecting NordVPN..."
        wgnord d 2>/dev/null || true
        msg "Down. $HS_IFACE will rejoin your normal Wi-Fi."
      }

      do_status() {
        if ip link show "$WG_IFACE" >/dev/null 2>&1; then
          echo "VPN     : up ($WG_IFACE)"
        else
          echo "VPN     : down"
        fi
        if nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$HS_PROFILE"; then
          local addr
          addr="$(ip -4 -o addr show "$HS_IFACE" 2>/dev/null | awk 'NR==1{print $4}')" || true
          echo "Hotspot : up (''${addr:-?} on $HS_IFACE)"
        else
          echo "Hotspot : down"
        fi
        if iptables -nL "$CHAIN" >/dev/null 2>&1; then
          echo "Routing : VPN-only kill-switch active"
        else
          echo "Routing : inactive"
        fi
      }

      case "''${1:-}" in
        up)     need_root "$@"; do_up ;;
        down)   need_root "$@"; do_down ;;
        status) need_root "$@"; do_status ;;
        *)      echo "Usage: vpn-hotspot {up|down|status}" >&2; exit 1 ;;
      esac
    '';
  };
in
{
  environment.systemPackages = [ vpn-hotspot ];

  # Hotspot client traffic must be forwarded into the VPN tunnel.
  boot.kernel.sysctl."net.ipv4.ip_forward" = true;
}
