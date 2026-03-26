{ ... }: {
  imports = [
    ./hardware.nix
    ./impermanence.nix
    ../../modules/core
    ../../modules/system/boot.nix
    ../../modules/system/graphics.nix
    ../../modules/system/audio.nix
    ../../modules/system/networking.nix
    ../../modules/system/fonts.nix
    ../../modules/system/input.nix
    ../../modules/system/users.nix
    ../../modules/gaming
  ];

  system.stateVersion = "25.11";
}
