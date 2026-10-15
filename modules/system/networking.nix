{ pkgs, ... }: {
  # --- NETWORKING ---
  # hostName is set per-host in hosts/<name>/default.nix
  networking.networkmanager.enable = true;
  networking.firewall.trustedInterfaces = [ "wlp12s0u1i3" ];

  # OpenVPN, system-wide and surviving reboots. Two pieces are needed and
  # neither does the job alone:
  #  * the NetworkManager plugin below, without which GNOME's
  #    Settings -> Network -> VPN -> "Import from file..." silently refuses
  #    every .ovpn. The plugin dir /run/current-system/sw/lib/NetworkManager/VPN
  #    was EMPTY before this (checked 2026-10-06), so there was no import path
  #    at all, with no error explaining why.
  #  * the `openvpn` CLI in systemPackages below, for running a .ovpn by hand
  #    or under a unit, independently of the desktop.
  # An imported connection is written to /etc/NetworkManager/system-connections,
  # which impermanence already persists (hosts/diana/impermanence.nix:119), so
  # importing once is enough and it comes back after every reboot.
  # Deliberately NO services.openvpn.servers.*: an always-on tunnel needs a
  # specific config plus credentials, and would start routing traffic unasked.
  # Add one here only when a given .ovpn is meant to be up at boot.
  networking.networkmanager.plugins = [ pkgs.networkmanager-openvpn ];

  # Wireless regulatory domain. The kernel boots with "00" (world), which
  # bans transmitting on 5 GHz, so a 5 GHz AP/hotspot cannot start. Pinned
  # to CL (Chile) to match this host's locale and timezone.
  hardware.wirelessRegulatoryDatabase = true;
  boot.extraModprobeConfig = ''
    options cfg80211 ieee80211_regdom=CL
  '';

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General.FastConnectable = true;
    # BlueZ 5.87 regression (commit 912f5efb0dd9, in the 5.87 release): the
    # A2DP endpoint-cache loader's loop guard `i < size && i >= 2` never runs
    # with i starting at 0, so every cached remote endpoint is discarded, SEP
    # discovery is forced on every connect, and when a headset initiates the
    # connection itself (Bose QC Ultra powering on) its SET_CONFIGURATION
    # arrives before the remote SEP is known: the transport is created under
    # the device path (dev_X/fd0) instead of the endpoint (dev_X/sep6/fd0),
    # ServicesResolved stays false, PipeWire's Acquire gets NotAuthorized,
    # and the headphones are "connected but silent" until a PC-initiated
    # reconnect. Live on Diana 2026-09-13. With the patch the sep-less path
    # and ServicesResolved=false persist on headset-initiated connects, but
    # the transport is idle and acquirable and audio flows (verified 11:30
    # the same day). Upstream fix "a2dp: Fix loading of
    # remote SEP from cache" (3f0cffa8df57, 2026-07-10) is in no release yet;
    # carried here on the daemon package only (nothing else links the daemon,
    # so no mass rebuild). Drop the patch when nixpkgs ships bluez > 5.87 —
    # it will stop applying. See also modules/system/audio.nix (bose-watch).
    package = pkgs.bluez.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        ./bluez-5.87-a2dp-fix-loading-of-remote-sep-from-cache.patch
      ];
    });
  };
  services.udev.extraRules = ''
  ACTION=="add", SUBSYSTEM=="bluetooth", TEST=="power/control", ATTR{power/control}="on"
  '';
  # wireguard-tools is here for `wg`, the only way to see whether a wgnord
  # tunnel is actually carrying traffic: handshake age, rx/tx, and the peer's
  # allowed IPs. Without it `wg show` simply fails, and a diagnostic that
  # swallows the error reports a healthy tunnel as dead — which happened on
  # 2026-10-10, where `handshake=none rx=0 tx=0` came from an ABSENT binary
  # while the tunnel was fine and the real fault was DNS (see nordvpn.nix).
  environment.systemPackages = [ pkgs.dnsutils pkgs.iw pkgs.openvpn pkgs.wireguard-tools ];  # wgnord: see nordvpn.nix
  services.tlp.enable = false;  # just in case
  systemd.tmpfiles.rules = [
    "w /sys/module/bluetooth/parameters/disable_ertm - - - - 1"
  ];
}
