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
    };
  services.udev.extraRules = ''
  ACTION=="add", SUBSYSTEM=="bluetooth", TEST=="power/control", ATTR{power/control}="on"
  '';
  environment.systemPackages = [ pkgs.wgnord pkgs.dnsutils pkgs.iw ];
  services.tlp.enable = false;  # just in case
  systemd.tmpfiles.rules = [
    "w /sys/module/bluetooth/parameters/disable_ertm - - - - 1"
  ];
}
