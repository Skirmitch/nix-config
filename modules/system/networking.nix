{ pkgs, ... }: {
  # --- NETWORKING ---
  networking.hostName = "Diana";
  networking.networkmanager.enable = true;
  hardware.bluetooth = { enable = true; powerOnBoot = true; };
  environment.systemPackages = [ pkgs.wgnord pkgs.dnsutils ];

}
