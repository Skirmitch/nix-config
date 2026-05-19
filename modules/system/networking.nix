{ pkgs, ... }: {
  # --- NETWORKING ---
  # hostName is set per-host in hosts/<name>/default.nix
  networking.networkmanager.enable = true;
  networking.firewall.trustedInterfaces = [ "wlp12s0u1i3" ];
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General.FastConnectable = true;
    };
  services.udev.extraRules = ''
  ACTION=="add", SUBSYSTEM=="bluetooth", TEST=="power/control", ATTR{power/control}="on"
  '';
  environment.systemPackages = [ pkgs.wgnord pkgs.dnsutils ];
  services.tlp.enable = false;  # just in case
  systemd.tmpfiles.rules = [
    "w /sys/module/bluetooth/parameters/disable_ertm - - - - 1"
  ];
}
