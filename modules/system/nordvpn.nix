{ pkgs, ... }:

# NordVPN via wgnord (NordLynx over wg-quick), made to coexist with Tailscale.
#
#   nordconnect / norddisconnect   (aliases -> sudo wgnord connect|disconnect)
#
# wgnord keeps its login state in /var/lib/wgnord (persisted in
# hosts/diana/impermanence.nix) and renders /etc/wireguard/wgnord.conf from
# /var/lib/wgnord/template.conf on every connect. The template is the only
# place WireGuard options can be set, so it is pinned here and symlinked in.
#
# Why the hooks exist (diagnosed 2026-09-11, tunnel healthy, DNS dead):
#  * wg-quick's catch-all policy rule lands at priority 5209, ahead of
#    Tailscale's table-52 rule at 5270. Anything for 100.64.0.0/10, including
#    DNS to the Tailscale resolver 100.100.100.100, was swallowed by the
#    tunnel. A rule at 5207 sends the tailnet to table 52 first.
#  * tailscaled re-registers itself as openresolv's exclusive resolver on every
#    link change, and openresolv honours the latest exclusive, so Nord's DNS
#    never reached /etc/resolv.conf. DNS is handed to the tunnel while it is
#    up and given back on disconnect (see extraSetFlags in tailscale.nix for
#    the reboot-mid-VPN case).
#  * NordLynx carries no IPv6. Rather than routing ::/0 into a black hole,
#    IPv6 is made explicitly unreachable while connected (metric 1 beats the
#    RA default at 100), so resolvers sort IPv4 first and nothing leaks.

let
  template = pkgs.writeText "wgnord-template.conf" ''
    [Interface]
    PrivateKey = PRIVKEY
    Address = 10.5.0.2/32
    DNS = 103.86.96.100, 103.86.99.100

    # Tailscale coexistence: route the tailnet before the tunnel's catch-all.
    PostUp   = ip -4 rule add to 100.64.0.0/10 lookup 52 priority 5207
    PostUp   = ip -6 rule add to fd7a:115c:a1e0::/48 lookup 52 priority 5207
    PostDown = ip -4 rule del priority 5207
    PostDown = ip -6 rule del priority 5207

    # Hand DNS to the tunnel while up; give it back to Tailscale after.
    PostUp   = tailscale set --accept-dns=false
    PostDown = tailscale set --accept-dns=true

    # No IPv6 through NordLynx: park it instead of black-holing it.
    PostUp   = ip -6 route add unreachable default metric 1
    PostDown = ip -6 route del unreachable default metric 1

    [Peer]
    PublicKey = SERVER_PUBKEY
    AllowedIPs = 0.0.0.0/0
    Endpoint = SERVER_IP:51820
    PersistentKeepalive = 25
  '';
in
{
  environment.systemPackages = [ pkgs.wgnord ];

  systemd.tmpfiles.rules = [
    # Pin the template (L+ replaces whatever wgnord left there).
    "L+ /var/lib/wgnord/template.conf - - - - ${template}"
    # Private keys must not be world-readable. wgnord truncates-in-place on
    # each connect, so the mode set here survives reconnects.
    "z /var/lib/wgnord/credentials.json 0600 root root - -"
    "z /var/lib/wgnord/auth_token       0600 root root - -"
    "z /etc/wireguard/wgnord.conf       0600 root root - -"
  ];
}
