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
    # base
    vim
    wget
    curl
    lm_sensors
    binutils
    python3
    usbutils
    nvd

    # archives
    unzip
    zip
    p7zip
    unrar

    # terminal essentials
    ripgrep
    fd
    fzf
    tree
    bat
    rsync

    # nix quality-of-life
    nix-output-monitor
    nix-tree
    nh
    comma            # run any pkg once; run `nix-index` once to build its db
    nix-index

    # disk / system
    ncdu
    lsof
    psmisc           # killall, pstree, fuser
    pv

    # network debugging
    dnsutils         # dig, nslookup
    mtr
    nmap
    ethtool

    # media / graphics
    ffmpeg
    yt-dlp
    mpv
    imagemagick
    flameshot
  ];
}
