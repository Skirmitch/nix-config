{ pkgs, ... }: {
  # --- BOOT & KERNEL ---
  boot.loader.systemd-boot = { enable = true; configurationLimit = 10; };
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelModules = [ "asus_ec_sensors" ];
  boot.initrd.systemd.enable = false;
  boot.kernelPackages = pkgs.linuxPackages_6_12;
}
