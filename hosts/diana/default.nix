{ nixosLabel, pkgs, ... }: {
  imports = [
    ./hardware.nix
    ./impermanence.nix
    ../../modules/core
    ../../modules/system/boot.nix
    ../../modules/system/graphics.nix
    ../../modules/system/nvidia.nix
    ../../modules/system/audio.nix
    ../../modules/system/networking.nix
    ../../modules/system/fonts.nix
    ../../modules/system/input.nix
    ../../modules/system/users.nix
    ../../modules/gaming
    ../../modules/apps/claude.nix
    ../../modules/apps/docker.nix
    ../../modules/apps/programming.nix
    ../../modules/apps/printing3d.nix
    ../../modules/apps/vr.nix
  ];

  networking.hostName = "Diana";

  # ASUS motherboard EC sensors
  boot.kernelModules = [ "asus_ec_sensors" ];

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

  system.nixos.label = nixosLabel;
  system.stateVersion = "25.11";
}
