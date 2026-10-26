{ config, utils, ... }:
let
  # THE DEVICE COMES FROM fileSystems, AND THAT IS NOT TIDINESS - it is the fix
  # for an outage this file caused.
  #
  # The scripted version hard-coded `/dev/nvme2n1p2`. At the 2026-10-22 19:30
  # boot the kernel went 7.2.10 -> 7.3.0 and the two NVMe controllers swapped
  # instance numbers. Same partition, same minor 259:9, new name:
  #
  #   Oct 15, 7.2.10:   nvme1n1: p1    nvme2n1: p1 p2   -> root = nvme2n1p2
  #   Oct 22, 7.3.0:    nvme2n1: p1    nvme1n1: p1 p2   -> root = nvme1n1p2
  #
  # The wipe ran without `set -e`, so the whole cascade was silent:
  #
  #   stage-1-init: mount: /mnt: special device /dev/nvme2n1p2 does not exist.
  #   stage-1-init: ERROR: Could not statfs: No such file or directory
  #   stage-1-init: umount: can't unmount /mnt: Invalid argument
  #   stage-1-init: mounting /dev/disk/by-uuid/3e5658eb-... on /...
  #
  # - and stage 1 then mounted the STALE root by-uuid as if nothing had
  # happened. `/` stopped being ephemeral for four days and nothing surfaced it,
  # because every fileSystems entry already uses by-uuid and the box booted
  # perfectly. Measured by ctime, not mtime (mtime is forgeable: an extracted
  # APK under /tmp carried 1979 stamps): 385,658 entries on `/` predated the
  # Oct 22 boot, while only 11 predated the Oct 15 one and every one of those
  # was a mountpoint or a /persist bind. 31 GB of /tmp was still live.
  #
  # The 2026-09-24 handoff called this exact shot - "Device node VARIES ACROSS
  # BOOTS - always by-uuid" - eleven days before it fired. Deriving the node
  # from fileSystems is what makes that advice structural instead of a note.
  rootDevice = config.fileSystems."/".device;
  rootDeviceUnit = "${utils.escapeSystemdPath rootDevice}.device";

  # --- PHASE TOGGLE: "probe" (Phase 1) -> "wipe" (Phase 2) ---
  #
  # The migration is deliberately two reboots, and this is the switch between
  # them. It exists so the ORDERING STANZAS BELOW ARE SHARED BYTE FOR BYTE
  # between the two phases: Phase 2 is a one-word edit here, not a re-paste that
  # could silently differ from the arrangement Phase 1 just proved.
  #
  # DELETE the probe branch and this toggle in Phase 3, once the wipe is
  # verified. It is migration scaffolding, not a feature.
  rollbackMode = "wipe";

  # Records what happened and DELETES NOTHING. One block is appended PER
  # INVOCATION, which is the whole point: if the re-run bug survived
  # RemainAfterExit, this boot writes TWO blocks instead of one, rather than the
  # re-run being assumed away. The file lands at the btrfs TOP LEVEL, so it
  # survives the wipe that Phase 2 turns on and is read back by mounting
  # subvolid=5.
  #
  # `if` rather than the handoff draft's `[ ... ] && already=yes`: measured
  # 2026-10-26 that both survive the `set -e` makeJobScript injects, so the
  # draft was not broken - this form is simply the same shape as the wipe's
  # guard below, and a unit that is requiredBy sysroot.mount is the wrong place
  # to leave a construct whose set -e behaviour has to be reasoned about.
  probeScript = ''
    already=no
    while read -r _ mp _; do
      if [ "$mp" = /sysroot ]; then already=yes; fi
    done < /proc/self/mounts

    mkdir -p /mnt
    mount -t btrfs -o subvol=/ ${rootDevice} /mnt
    {
      echo "=== $(date -Is 2>/dev/null || echo no-date) invocation"
      if [ "$already" = yes ]; then
        echo "FAIL - /sysroot ALREADY MOUNTED (ordering broke, or this is a re-run)"
      else
        echo "OK - ordering holds"
      fi
    } >> /mnt/ordering-probe.txt
    sync
    umount /mnt
  '';

  wipeScript = ''
    # A stray second invocation must be a no-op, not gen 127 again - but it
    # must SAY SO. With this guard a broken ordering looks identical to a
    # harmless re-run: both exit 0 and neither wipes. That is the exact shape
    # of the four-day failure described above, so the one thing it must never
    # do is stay quiet. The journal lives on @log, which survives the wipe, so
    # `journalctl -b -u rollback` keeps the evidence either way.
    while read -r _ mp _; do
      if [ "$mp" = /sysroot ]; then
        echo "rollback: /sysroot already mounted - NOT wiping." \
             "Either this is the documented re-run, or the ordering broke."
        exit 0
      fi
    done < /proc/self/mounts

    mkdir -p /mnt
    # Guard 1: a failed mount must FAIL, not fall through. Without this the
    # steps below are silent no-ops against an empty /mnt and the only thing
    # returning non-zero is the final `umount` - i.e. the script is fail-closed
    # by accident, not by design. That exact shape hid a dead wipe for 4 days
    # (see the nvme-renumber incident).
    mount -t btrfs -o subvol=/ ${rootDevice} /mnt || { echo "rollback: mount of ${rootDevice} FAILED - refusing to touch anything"; exit 1; }

    # Guard 2: verify the DESTINATION before destroying the source. The park
    # below moves the live root aside and the snapshot that replaces it happens
    # at the very end; if @root-blank were missing we would already have parked
    # @root and have no / to boot.
    [ -e /mnt/@root-blank ] || { echo "rollback: @root-blank MISSING - refusing to park @root"; exit 1; }

    if [ -e /mnt/@root ]; then
      mkdir -p /mnt/old_roots
      mv /mnt/@root "/mnt/old_roots/@root_$(date +%Y-%m-%d_%H-%M-%S)"
    fi

    # RETENTION - keep the 2 newest parked roots.
    #
    # Carried over from the scripted version deliberately. The handoff's own
    # prerequisite says so, and its draft change block contradicted itself by
    # replacing the move-aside with a bare delete: the parked roots ARE the
    # forensic record for this migration - both May failures were diagnosed by
    # reading them. Without retention 57 roots once accumulated (~175 GiB).
    #
    # A bash glob expands already sorted, and @root_YYYY-MM-DD_HH-MM-SS sorts
    # lexically == chronologically, so the newest two are simply the last two.
    # No `ls`, no command substitution, no word splitting - which is what let
    # a name containing a space hand the btrfs TOP LEVEL to the old recursive
    # delete and take @home and @persist with it.
    shopt -s nullglob
    parked=(/mnt/old_roots/@root_*)
    shopt -u nullglob
    n=''${#parked[@]}
    if [ "$n" -gt 2 ]; then
      for p in "''${parked[@]:0:$((n - 2))}"; do
        # Belt: never hand `delete -R` anything outside old_roots.
        case "$p" in
          /mnt/old_roots/@root_*) btrfs subvolume delete -R "$p" ;;
        esac
      done
    fi

    # `delete -R`, not the hand-rolled `subvolume list -o` recursion the
    # scripted version needed: a plain delete fails ENOTEMPTY because NixOS
    # makes /srv and /var/tmp nested subvolumes. btrfs-progs 7.1 has -R.
    btrfs subvolume snapshot /mnt/@root-blank /mnt/@root
    umount /mnt
  '';
in
{

  # --- INITRD WIPE UNIT (systemd stage 1) ---
  #
  # Was `boot.initrd.postDeviceCommands`. nixpkgs REMOVED scripted initrd in the
  # 2026-10-26 input bump: both that option and `boot.initrd.systemd.enable` are
  # now `mkRemovedOptionModule` (nixos/modules/system/boot/systemd/initrd.nix
  # :194-216), so eval refuses outright and the `enable = false` escape hatch is
  # gone. This migration is no longer optional and no longer deferrable.
  #
  # IT FAILED TWICE IN MAY 2026, and the cause was NOT the ordering: the unit
  # RAN TWICE. `Type=oneshot` without RemainAfterExit leaves a finished unit
  # inactive, so its start job is never redundant (job.c:446-448);
  # initrd-cleanup.service isolates initrd-switch-root.target, which pulls
  # sysroot.mount, which pulls this unit again - and transaction_collect_garbage
  # is skipped in JOB_ISOLATE mode (transaction.c:749,774). Gen 126 moved the
  # ALREADY-MOUNTED live root into old_roots on its second pass; gen 127 deleted
  # it mid-switch-root and hung. Poettering prescribed RemainAfterExit=yes for
  # exactly this in systemd#29367; zfs.nix, bcachefs.nix and initrd.nix all do
  # it. The guards in both scripts above are the second belt.
  boot.initrd.systemd.services.rollback = {
    description = "Roll @root back to a pristine @root-blank snapshot";
    # `before` alone never pulls a unit into the transaction; this does.
    wantedBy = [ "initrd.target" ];
    after = [ rootDeviceUnit ];
    requires = [ rootDeviceUnit ];
    before = [ "sysroot.mount" "shutdown.target" ];
    # Fail CLOSED. Misterio77's widely-copied config omits this and boots a
    # stale root silently when the rollback fails - which is precisely the
    # failure mode that went unnoticed for four days above.
    requiredBy = [ "sysroot.mount" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;      # <- THE FIX. See the May 2026 note above.
      TimeoutStartSec = "180s";    # a stall fails to emergency instead of hanging
    };
    # NO `path`: stage1ServiceConfig omits the stage-2 defaults
    # (systemd-lib.nix:648-650,710), so setting it would REPLACE PATH and hide
    # /bin's coreutils. The initrd already has coreutils, bash, btrfs-progs
    # (btrfs.nix:118) and mount/umount. The script runs under bash with `set -e`
    # injected by makeJobScript (systemd-lib.nix:555) - every line is written to
    # survive that.
    script = if rollbackMode == "probe" then probeScript else wipeScript;
  };

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
