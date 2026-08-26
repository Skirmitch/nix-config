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

    # text / data wrangling  (added 2026-08-26 — agent sessions kept hitting these)
    bc               # the one genuinely missing tool from the reported list
    jq               # was per-user only; agents run outside the HM profile
    yq-go            # yaml/xml -> jq semantics
    xmlstarlet
    jo               # build JSON from the shell
    jc               # convert ordinary command output to JSON
    miller           # mlr: csv/tsv/json streams
    datamash
    dos2unix
    moreutils        # sponge, ts, chronic, ifne, errno, vipe

    # process / debugging
    htop             # btop is per-user only
    ltrace           # strace already present via nixos defaults
    gdb
    tcpdump
    iotop
    socat            # only reachable today via Claude Code's own wrapper — declare it
    entr             # rerun on file change
    hyperfine        # honest benchmarking instead of `time` guesswork
    parallel         # GNU parallel
    tmux

    # build basics
    gnumake
    gcc              # NOTE: no lib headers on NixOS; use a devshell for real builds
    pkg-config

    # desktop glue
    wl-clipboard     # wl-copy / wl-paste — Wayland has no xclip path
  ];
}
