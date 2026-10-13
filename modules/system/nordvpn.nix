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
#
# Why this is an OVERLAY and not a let-bound package (2026-10-10):
# shipping the patched build in systemPackages alone fixed `nordconnect` and
# left every other caller on upstream's hookless template. vpn-hotspot.nix
# listed plain `pkgs.wgnord` in runtimeInputs, writeShellApplication prepends
# those to PATH, so `vpn-hotspot up` ran the 215-byte config: no rule at 5207,
# no accept-dns=false, and AllowedIPs = 0.0.0.0/0, ::/0. /etc/resolv.conf holds
# only Tailscale's resolvers, so BOTH were swallowed - 100.100.100.100 by the
# IPv4 catch-all and fd7a:115c:a1e0::53 by ::/0 into a tunnel with no IPv6 -
# giving the same signature as 09-11 and 09-24: tunnel healthy, DNS dead, for
# as long as the hotspot was up. An overlay makes pkgs.wgnord the hooked build
# for every consumer, so the next module to want it cannot get this wrong.

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
  # wgnord 0.2.2 no longer renders from /var/lib/wgnord/template.conf: nixpkgs
  # patches the path to the store copy at build time
  # (pkgs/by-name/wg/wgnord/package.nix, `--replace-fail '$conf_dir/template.conf'
  # "$out/share/template.conf"`), so the tmpfiles pin below went inert and took
  # every hook above with it. Diagnosed 2026-09-24 after the 09-22 nixpkgs bump
  # carried 0.2.1 -> 0.2.2: tunnel healthy, DNS dead, nsncd's 8 workers blocking
  # on lookups the tunnel swallowed and the daemon exiting about once a minute.
  # The give-away needs no reconnect: the template is 827 bytes, upstream's is
  # 215, and the rendered /etc/wireguard/wgnord.conf was 287 = 215 + the keys.
  # The path is baked in during the UNRESHOLVED build, so overriding postPatch
  # on the resolved derivation does nothing (verified: the built script still
  # pointed at the 215-byte upstream copy). Rewrite it in the finished script
  # instead. --replace-fail is the trip wire: if nixpkgs ever stops pointing at
  # $unresholved/share/template.conf, this fails the build rather than silently
  # handing the tunnel a hookless config again.
  wgnordTemplateOverlay = final: prev: {
    wgnord = prev.wgnord.overrideAttrs (old: {
      postFixup = (old.postFixup or "") + ''
        substituteInPlace $out/bin/wgnord \
          --replace-fail "${prev.wgnord.unresholved}/share/template.conf" "${template}"
      '';
    });
  };
in
{
  nixpkgs.overlays = [ wgnordTemplateOverlay ];

  environment.systemPackages = [ pkgs.wgnord ];

  systemd.tmpfiles.rules = [
    # Kept for the day upstream honours $conf_dir again: harmless while inert,
    # and it is what wgnord's own --help still tells you to edit.
    "L+ /var/lib/wgnord/template.conf - - - - ${template}"
    # Private keys must not be world-readable. wgnord truncates-in-place on
    # each connect, so the mode set here survives reconnects.
    "z /var/lib/wgnord/credentials.json 0600 root root - -"
    "z /var/lib/wgnord/auth_token       0600 root root - -"
    "z /etc/wireguard/wgnord.conf       0600 root root - -"
  ];
}
