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
    ../../modules/system/vpn-hotspot.nix
    ../../modules/system/hotspot.nix
    ../../modules/system/fonts.nix
    ../../modules/system/input.nix
    ../../modules/system/users.nix
    ../../modules/gaming
    ../../modules/apps/claude.nix
    ../../modules/apps/docker.nix
    ../../modules/apps/programming.nix
    ../../modules/apps/printing3d.nix
    ../../modules/apps/vr.nix
    ../../modules/apps/sunshine.nix
    ../../modules/apps/immersed.nix
  ];

  networking.hostName = "Diana";

  # ASUS motherboard EC sensors
  boot.kernelModules = [ "asus_ec_sensors" ];

  # Was pinned to 7.0.5: 7.0.8 regressed MT7921U BT (WMT func ctrl -22 on
  # init). Fixed upstream ("btmtk: accept too short WMT FUNC_CTRL events"),
  # present in 7.0.11 — unpinned 2026-06-08.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  system.nixos.label = nixosLabel;
  system.stateVersion = "25.11";
}
