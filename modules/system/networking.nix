{ pkgs, ... }: {
  # --- NETWORKING ---
  # hostName is set per-host in hosts/<name>/default.nix
  networking.networkmanager.enable = true;
  networking.firewall.trustedInterfaces = [ "wlp12s0u1i3" ];

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
  environment.systemPackages = [ pkgs.dnsutils pkgs.iw ];  # wgnord: see nordvpn.nix
  services.tlp.enable = false;  # just in case
  systemd.tmpfiles.rules = [
    "w /sys/module/bluetooth/parameters/disable_ertm - - - - 1"
  ];
}
