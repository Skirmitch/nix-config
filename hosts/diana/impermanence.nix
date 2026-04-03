{ lib, ... }: {

  # --- INITRD WIPE SCRIPT ---
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    mkdir /mnt
    mount -t btrfs /dev/nvme2n1p2 /mnt
    if [ -e /mnt/@root ]; then
        mkdir -p /mnt/old_roots
        timestamp=$(date +%Y-%m-%d_%H-%M-%S)
        mv /mnt/@root "/mnt/old_roots/@root_$timestamp"
    fi

    delete_subvolumes() {
        IFS=$'\n'
        for i in $(btrfs subvolume list -o "$1" | cut -f 9- -d ' '); do
            delete_subvolumes "/mnt/$i"
        done
        btrfs subvolume delete "$1"
    }

    btrfs subvolume snapshot /mnt/@root-blank /mnt/@root
    umount /mnt
  '';

  # --- PERSISTENCE DEFINITIONS ---
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/lib/bluetooth"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/etc/NetworkManager/system-connections"
      "/var/lib/wgnord"
      "/etc/wireguard"
      "/var/lib/docker"
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
        ".config/Claude"
        ".local/share/anime-game-launcher"
        ".local/share/dconf"
        ".config/dconf"
        ".local/share/gnome-shell"
        ".config/gnome-session"
        "Downloads"
        "Documents"
        "Pictures"
        "Videos"
        ".config/Code"
        ".vscode"
        ".config/JetBrains"       
        ".local/share/JetBrains"  
        ".aws"
        ".config/easyeffects"
      ];
    };
  };
}
