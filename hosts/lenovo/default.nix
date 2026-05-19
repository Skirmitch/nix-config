{ nixosLabel, pkgs, ... }: {
  imports = [
    ./hardware.nix
    ./impermanence.nix
    ../../modules/core
    ../../modules/system/boot.nix
    ../../modules/system/graphics.nix
    ../../modules/system/intel-graphics.nix
    # If this Lenovo has a discrete NVIDIA GPU, also import:
    #   ../../modules/system/nvidia.nix
    ../../modules/system/audio.nix
    ../../modules/system/networking.nix
    ../../modules/system/fonts.nix
    ../../modules/system/input.nix
    ../../modules/system/users.nix
    ../../modules/gaming
    ../../modules/apps/claude.nix
    ../../modules/apps/docker.nix
    ../../modules/apps/programming.nix
    # printing3d is desktop-only; uncomment if you want it on the laptop too.
    # ../../modules/apps/printing3d.nix
  ];

  networking.hostName = "lenovo"; # rename to whatever you want

  # Laptop power management.
  services.thermald.enable = true;
  services.power-profiles-daemon.enable = true;

  system.nixos.label = nixosLabel;
  system.stateVersion = "25.11";
}
