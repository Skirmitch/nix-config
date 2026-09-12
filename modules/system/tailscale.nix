{ pkgs, ... }: {
  # --- Tailscale: WireGuard mesh, used as the inbound path to this host ---
  # Diana sits behind CGNAT-ish home NAT with no port forwarding, and wgnord
  # is strictly *outbound* (it gives no route back in). Tailscale supplies the
  # NAT traversal so the phone can reach services on this box from mobile data
  # without exposing anything to the public internet.
  #
  # First run is interactive (browser SSO), so the node is NOT authenticated
  # declaratively:  sudo tailscale up
  # State (node key, machine identity) lives in /var/lib/tailscale — persisted
  # in hosts/diana/impermanence.nix, otherwise the node re-registers on every
  # boot and its name gains a -1, -2, … suffix.

  services.tailscale = {
    enable = true;
    openFirewall = true;   # UDP 41641, the direct-connection port; without it
                           # sessions fall back to the slower DERP relays
    # nordvpn.nix hands DNS to the Nord tunnel with `tailscale set
    # --accept-dns=false` while it is up and restores it on disconnect. A
    # reboot mid-VPN would skip the restore and leave MagicDNS off, so the
    # flag is re-asserted at every boot (tailscaled-set.service).
    extraSetFlags = [ "--accept-dns=true" ];
  };

  # Treat the mesh as trusted. Everything on tailscale0 is an authenticated
  # node from this tailnet, so per-service firewall holes (RDP 3389, Sunshine)
  # are opened on this interface only, never on the LAN or the WAN.
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  environment.systemPackages = [ pkgs.tailscale ];
}
