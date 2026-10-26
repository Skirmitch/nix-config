{ utils, ... }:
let
  # TODO: replace with the laptop's real by-uuid node (and uncomment
  # fileSystems."/" in hardware.nix), then this file matches Diana exactly.
  # NEVER a /dev/nvmeXnYpZ path - see the header of hosts/diana/impermanence.nix
  # for the four-day outage that naming style caused on 2026-10-22.
  rootDevice = "/dev/REPLACE-ME";
  rootDeviceUnit = "${utils.escapeSystemdPath rootDevice}.device";
in
{

  # --- INITRD WIPE UNIT (systemd stage 1) ---
  # Mirrors Diana, minus the retention loop: this host has never booted, so it
  # has no parked roots to trim. Scripted initrd was removed from nixpkgs in the
  # 2026-10-26 bump, so the old postDeviceCommands hook no longer evaluates.
  # Kept building-but-not-bootable, same as the rest of hosts/lenovo.
  boot.initrd.systemd.services.rollback = {
    description = "Roll @root back to a pristine @root-blank snapshot";
    wantedBy = [ "initrd.target" ];
    after = [ rootDeviceUnit ];
    requires = [ rootDeviceUnit ];
    before = [ "sysroot.mount" "shutdown.target" ];
    requiredBy = [ "sysroot.mount" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;      # see Diana's copy for why this line exists
      TimeoutStartSec = "180s";
    };
    script = ''
      while read -r _ mp _; do
        if [ "$mp" = /sysroot ]; then exit 0; fi
      done < /proc/self/mounts

      mkdir -p /mnt
      mount -t btrfs -o subvol=/ ${rootDevice} /mnt
      if [ -e /mnt/@root ]; then
        mkdir -p /mnt/old_roots
        mv /mnt/@root "/mnt/old_roots/@root_$(date +%Y-%m-%d_%H-%M-%S)"
      fi
      btrfs subvolume snapshot /mnt/@root-blank /mnt/@root
      umount /mnt
    '';
  };

  # --- PERSISTENCE DEFINITIONS ---
  # Kept identical to Diana so the user experience is the same.
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
        ".config/cura"
        ".config/OrcaSlicer"
        ".config/libreoffice"
        ".config/obsidian"
        # Zoom keeps its signed-in session, chat history, and local
        # recordings in ~/.zoom; ~/.config/zoomus.conf holds the client
        # settings (audio/video device picks, view prefs). Without both,
        # every reboot means logging in and reconfiguring devices again.
        ".zoom"
       ];
      files = [
        ".config/zoomus.conf"
      ];
    };
  };
}
