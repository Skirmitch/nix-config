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
        # GUARD 1 of 2 - the target MUST be inside old_roots/@root_*.
        #
        # Two separate escapes make this necessary, both verified against the
        # real initrd busybox in a VM:
        #
        #  (a) WORD SPLITTING. The retention loop below used an unquoted
        #      $(...), so a parked entry named `@root_x mnt` split into two
        #      words and handed the bare word `mnt` to this function. Stage 1
        #      runs with cwd=/, so `mnt` resolves to the btrfs TOP LEVEL, which
        #      is itself a subvolume root (inode 256) and sailed past guard 2.
        #      `btrfs subvolume list -o mnt` then returned every top-level
        #      subvolume and the recursion deleted @home, @persist, @nix, @log
        #      and @root-blank. A single SPACE in a name was the whole exploit.
        #
        #  (b) EMBEDDED NEWLINES. `btrfs subvolume list` prints names raw
        #      (btrfs-progs 7.1 cmds/subvolume-list.c:1198, no escaping), and
        #      IFS is a newline here, so a nested subvolume named
        #      "x<newline>@nix" yielded a second word `@nix` -> /mnt/@nix.
        #      Creating a subvolume is UNPRIVILEGED, and /tmp and /var/tmp are
        #      1777, so any local process could plant a delayed root-level
        #      delete that fires two boots later.
        #
        # This prefix test rejects every such fragment: `mnt`, `@nix`,
        # `/mnt/@home` - none of them start with /mnt/old_roots/@root_.
        case "$1" in
            /mnt/old_roots/@root_*) ;;
            *) return 0 ;;
        esac

        # GUARD 2 of 2 - the target must be a real subvolume ROOT.
        #
        # `btrfs subvolume list -o <path>` does NOT fail on a non-subvolume: it
        # falls back to the tree CONTAINING that path (lookup_path_rootid), and
        # for anything under old_roots/ that tree is the btrfs TOP LEVEL, id 5.
        # The -o filter would then list @home, @persist, @nix, @log and
        # @root-blank as "children", and this recursion would delete every one
        # of them, leaving /home and /persist destroyed and the machine
        # unbootable. Nothing is mounted here, so every delete would succeed.
        #
        # A plain directory named @root_* in old_roots is enough to trigger it -
        # e.g. a `mkdir`, `cp -a` or `cp --reflink` rescue done by hand at the
        # top level, which is exactly the kind of thing the two retained roots
        # exist to invite during the systemd-initrd migration.
        #
        # Subvolume roots ALWAYS have inode 256; plain directories never do
        # (verified on this box: / /home /persist /nix = 256, /etc = 271).
        # busybox stat does not dereference, so a symlink is skipped too.
        [ "$(stat -c %i "$1" 2>/dev/null)" = 256 ] || return 0
        IFS=$'\n'
        for i in $(btrfs subvolume list -o "$1" | cut -f 9- -d ' '); do
            delete_subvolumes "/mnt/$i"
        done
        btrfs subvolume delete "$1"
    }

    # RETENTION - keep only the 2 most recent parked roots.
    #
    # Without this the move-aside above never deleted anything: 57 roots had
    # accumulated by 2026-09-25 (~175 GiB, the single largest non-game item on
    # the disk). delete_subvolumes() was defined here from the start and simply
    # never called. Worse, /tmp lives on @root rather than tmpfs, so every
    # boot's /tmp is frozen forever too - one agent-workflow day parked 34 GiB
    # of `git clone --shared` trees under /tmp/closure-w1-*.
    #
    # TWO are kept deliberately, not for safety margin but as the rollback
    # evidence for the pending systemd-initrd migration: if the new unit wipes
    # or parks the wrong subvolume again (it did twice in May 2026), the
    # previous boots' roots are what we inspect to work out what happened.
    #
    # Placement matters: this MUST sit after delete_subvolumes() is defined.
    # busybox ash resolves a function only once its definition has been
    # executed, so calling it earlier fails with "not found" - and because the
    # wipe script runs without `set -e`, that failure is silent and the leak
    # quietly continues.
    #
    # Names sort chronologically (@root_YYYY-MM-DD_HH-MM-SS), so reverse-sort
    # and drop the first two. `tail -n +3` is busybox-safe; `head -n -2` is not.
    # `while IFS= read -r` instead of `for i in $(...)`: the unquoted command
    # substitution split names on spaces and tabs AND glob-expanded them, which
    # is escape (a) described above. read -r with an empty IFS takes each line
    # whole and does no globbing.
    ls -1d /mnt/old_roots/@root_* 2>/dev/null | sort -r | tail -n +3 |
    while IFS= read -r parked; do
        delete_subvolumes "$parked"
    done

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
      # GNOME's Power panel (Performance / Balanced / Power Saver) is backed by
      # power-profiles-daemon, which saves the chosen profile to
      # /var/lib/power-profiles-daemon/state.ini and restores it at startup
      # (load_configuration() in power-profiles-daemon.c, then a Profile= read
      # gated on the CpuDriver/PlatformDriver still matching). On the wiped
      # @root that file was recreated empty every boot, so the daemon fell back
      # to `balanced` and "Performance" never survived a reboot. Same shape as
      # the systemd timer stamps above.
      "/var/lib/power-profiles-daemon"
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
        # ".local/share/anime-game-launcher" MOVED 2026-09-26 to /mnt/bulk on the
        # second NVMe (148 G, 145 of it Genshin). See modules/system/bulk-storage.nix.
        # It must NOT be listed here: impermanence would bind /persist over the new
        # mount, you would still see the old data, and no space would be freed.
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
        # ".local/share/Steam" MOVED 2026-09-26 to /mnt/bulk (212 G). Same reason as
        # anime-game-launcher above. ".steam" stays: it is 44 K of symlinks/config.
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
