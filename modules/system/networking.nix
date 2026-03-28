{ ... }: {
  # --- NETWORKING ---
  networking.hostName = "Diana";
  networking.networkmanager.enable = true;
  hardware.bluetooth = { enable = true; powerOnBoot = true; };
  services.nordvpn.enable = true;
}
