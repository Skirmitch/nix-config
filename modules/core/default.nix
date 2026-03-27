{ pkgs, ... }: {
  imports = [ ./locale.nix ];

  # --- NIX SETTINGS ---
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # Firmware management
  hardware.enableAllFirmware = true;
  hardware.firmware = [ pkgs.linux-firmware ];

  # Garbage Collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Core system tools
  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    lm_sensors
    binutils
  ];
}
