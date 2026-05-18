{ pkgs, ... }: {
  # --- BOOT & KERNEL ---
  boot.loader.systemd-boot = { enable = true; configurationLimit = 10; };
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelModules = [ "asus_ec_sensors" ];
  boot.initrd.systemd.enable = false;
  # Pinned to 7.0.5: 7.0.8 regressed MT7921U BT (WMT cmd failure on init).
  boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linux_latest.override {
    argsOverride = rec {
      version = "7.0.5";
      modDirVersion = version;
      src = pkgs.fetchurl {
        url = "mirror://kernel/linux/kernel/v7.x/linux-${version}.tar.xz";
        hash = "sha256-ll+wocFnU5n8YMYGOyJ8BSMEG1+aZitmRi8SEsQ4rDw=";
      };
    };
  });
}
