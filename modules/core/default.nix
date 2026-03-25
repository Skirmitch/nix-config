{ pkgs, ... }: {
  # --- NIX SETTINGS ---
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;
  
  # Firmware management [cite: 4, 5]
  hardware.enableAllFirmware = true; 
  hardware.firmware = [ pkgs.linux-firmware ];

  # Garbage Collection [cite: 5, 6]
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # --- LOCALIZATION --- [cite: 8, 9, 10]
  time.timeZone = "America/Santiago";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "es_CL.UTF-8";
    LC_IDENTIFICATION = "es_CL.UTF-8";
    LC_MEASUREMENT = "es_CL.UTF-8";
    LC_MONETARY = "es_CL.UTF-8";
    LC_NAME = "es_CL.UTF-8";
    LC_NUMERIC = "es_CL.UTF-8";
    LC_PAPER = "es_CL.UTF-8";
    LC_TELEPHONE = "es_CL.UTF-8";
    LC_TIME = "es_CL.UTF-8";
  };

  # Core system tools [cite: 27]
  environment.systemPackages = with pkgs; [
    vim 
    wget
    curl
    lm_sensors
  ];
}
