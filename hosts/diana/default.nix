{ nixosLabel, ... }: {
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
    ../../modules/apps/claude.nix
    ../../modules/apps/docker.nix
    ../../modules/apps/programming.nix
    ../../modules/apps/printing3d.nix
  ];
  
  system.nixos.label = nixosLabel;
  system.stateVersion = "25.11";
}
