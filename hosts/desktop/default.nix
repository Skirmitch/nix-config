{ config, pkgs, lib, inputs,  ... }: { # Added 'lib' here 
  imports = [ 
    ./hardware.nix 
    ../../modules/core
  ];

  # --- INITRD WIPE SCRIPT ---
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    mkdir /mnt
    mount -t btrfs /dev/nvme2n1p2 /mnt
    if [ -e /mnt/@root ]; then
        mkdir -p /mnt/old_roots
        timestamp=$(date +%Y-%m-%d_%H-%M-%S)
        # We move it to the safety of old_roots 
        mv /mnt/@root "/mnt/old_roots/@root_$timestamp"
    fi

    delete_subvolumes() {
        IFS=$'\n'
        for i in $(btrfs subvolume list -o "$1" | cut -f 9- -d ' '); do
            delete_subvolumes "/mnt/$i"
        done
        btrfs subvolume delete "$1"
    }

    # FIX: We only need to delete the subvolumes if we are restoring.
    # The new root is a fresh snapshot of the blank one.
    btrfs subvolume snapshot /mnt/@root-blank /mnt/@root
    umount /mnt
  '';

  # --- PERSISTENCE DEFINITIONS --- 
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
#      "/var/log"
      "/var/lib/bluetooth"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/etc/NetworkManager/system-connections"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
    users.skirmitch = {
      directories = [
        "nix-config"              
        ".ssh"                    
        ".local/share/fcitx5"     
        ".config/vivaldi"         
        ".config/discord"
        ".local/share/anime-game-launcher"
        "Downloads"
        "Documents"
        "Pictures"
        "Videos"
        # If your 3,000 books are in a specific folder, add it here!
      ];
    };
  };

  # --- Networking ---

  networking.hostName = "Diana"; 
  networking.networkmanager.enable = true;
  hardware.bluetooth = { enable = true; powerOnBoot = true; }; 

  # --- BOOT & KERNEL --- 
  boot.loader.systemd-boot = { enable = true; configurationLimit = 10; };
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelModules = [ "asus_ec_sensors" ];
  boot.kernelParams = [ "nvidia.NVreg_EnableGpuFirmware=0" ];
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # --- GRAPHICS (RTX 3060 Ti) --- 
  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" ];
    deviceSection = ''Option "Coolbits" "12"''; # For your fan control
  };

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  hardware.graphics = { enable = true; enable32Bit = true; };

  hardware.nvidia = {
    powerManagement.enable = true;
    nvidiaSettings = true;
    modesetting.enable = true;
    open = false;
    package = (config.boot.kernelPackages.nvidiaPackages.stable.overrideAttrs {
      src = pkgs.fetchurl {
        url = "https://us.download.nvidia.com/XFree86/Linux-x86_64/595.45.04/NVIDIA-Linux-x86_64-595.45.04.run";
        sha256 = "sha256-zUllSSRsuio7dSkcbBTuxF+dN12d6jEPE0WgGvVOj14=";
      };
    });
  };

  # --- INPUT & FONTS --- 
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.waylandFrontend = true;
    fcitx5.addons = with pkgs; [ fcitx5-mozc fcitx5-gtk qt6Packages.fcitx5-configtool ];
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans 
    noto-fonts-color-emoji
    roboto # Re-added!
  ];

  # --- GAMING & SOUND --- 
  programs.steam.enable = true;
  hardware.xpadneo.enable = true;
  services.pipewire = { enable = true; pulse.enable = true; };

  # --- GENSHIN IMPACT (AAGL) ---
  nix.settings = {
    substituters = [ "https://ezkea.cachix.org" ];
    trusted-public-keys = [ "ezkea.cachix.org-1:ioBmUbJTZIKsHmWWXPe1FSFbeVe+afhfgqgTSNd34eI=" ];
  };
  programs.anime-game-launcher.enable = true;

  # This ensures the launcher has the right permissions for your RTX 3060 Ti
  # and doesn't struggle with the stateless root.
  nixpkgs.overlays = [
    inputs.aagl.overlays.default
  ];


  # --- USER DEFINITION --- 
  users.users.skirmitch = {
    isNormalUser = true;
    description = "Skirmitch";
    extraGroups = [ "networkmanager" "wheel" "video" "dialout" ];
    hashedPassword = "$y$j9T$z7hQ9X7Lykrjb38n3V2y8/$jS7EbPmQZQHHt1VS8wTAHtTOS.YtgXK7BtU.H75iiL0"
  };

  users.users.root = {
  hashedPassword = "$y$j9T$//7vocA0e8I58ihBSCM1.1$GWGXy9DfvYZPxQt8WYMWn9DQco2ACo8Dlt2vZ3RXf/7";
};


  system.stateVersion = "25.11"; 
}
