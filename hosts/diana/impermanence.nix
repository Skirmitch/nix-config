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
      # systemd's timer stamp files. Every `Persistent = true` timer on this box
      # was silently neutered without this: Persistent= replays a missed
      # OnCalendar= trigger by comparing the wall clock against a stamp file in
      # /var/lib/systemd/timers, which lived on the wiped @root and was recreated
      # empty at every boot. So a nightly job missed while the box was off was
      # never caught up - fstrim.timer and nix-gc.timer as much as hc-backup.timer
      # (v3 finding 60; verified: every stamp file's mtime was the last boot).
      "/var/lib/systemd/timers"
      "/etc/NetworkManager/system-connections"
      "/var/lib/wgnord"
      "/etc/wireguard"
      # Tailscale node key + machine identity. Without this the node
      # re-registers on every boot and comes back as diana-1, diana-2, …
      "/var/lib/tailscale"
      # gnome-remote-desktop's system daemon state (remote-login side).
      "/var/lib/gnome-remote-desktop"
      "/var/lib/docker"
      "/var/lib/postgresql"
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
        # FreeCAD: user.cfg/system.cfg prefs under .config; Mod/, Macro/, the
        # Addon Manager cache and the MCP addon's freecad_mcp_settings.json
        # (auto-start RPC toggle) under .local/share.
        ".config/FreeCAD"
        ".local/share/FreeCAD"
        ".config/LibreCAD"
        ".config/libreoffice"
        ".config/obsidian"
        ".config/wivrn"
        ".config/openxr"
        ".config/sunshine"
        # RDP TLS keypair for desktop sharing. Losing it means the phone's
        # RDP client warns about a changed certificate after every reboot.
        # (The RDP password itself lives in .local/share/keyrings, above.)
        ".local/share/gnome-remote-desktop"
        ".android"
        ".config/SideQuest"
        ".steam"
        ".local/share/Steam"
        ".claude"
        ".config/gh"
        ".config/opencode"
        ".local/share/opencode"
        ".local/share/keyrings"
        # ON1 Photo RAW via Lutris/GE-Proton: the Wine prefix (~/Games/…)
        # holds ON1's license activation, settings, and catalog DB — losing
        # it on reboot means reactivating and recataloguing. Runners
        # (GE-Proton) and the Lutris game DB live under .local/share/lutris.
        "Games"
        ".local/share/lutris"
        ".config/lutris"
        ".local/share/umu"
        ".config/pupgui"
        # Zoom keeps its signed-in session, chat history, and local
        # recordings in ~/.zoom; ~/.config/zoomus.conf holds the client
        # settings (audio/video device picks, view prefs). Without both,
        # every reboot means logging in and reconfiguring devices again.
        ".zoom"
       ];
      files = [
        ".gitconfig"
        ".config/zoomus.conf"
      ];
    };
  };
}
