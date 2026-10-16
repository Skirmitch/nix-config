{ pkgs, ... }:
let
  # The project folders Claude Code keeps for the cycle-hq seats. The name is the
  # seat's cwd with every `/` turned into `-`, so they all begin with a dash: that
  # is why every path below is absolute and never a bare argument.
  srcPrefix = "/home/skirmitch/.claude/projects/-home-skirmitch-cycle-hq";
  dest = "/mnt/bulk/claude-transcripts-archive";
  # Snapshots must live OUTSIDE the subvolume they snapshot, so they are a sibling
  # of the archive rather than a directory inside it.
  snapDir = "/mnt/bulk/transcript-archive-snapshots";

  # Same shape as health-store.nix: one hardening block, inheriting an unused
  # restriction is cheaper than a second subtly different one.
  #
  # Three deliberate differences from that block:
  #   ProtectHome = "read-only" - this unit's whole job is to READ ~/.claude, so
  #     ProtectHome = true (health-store's value) would break it. "read-only" is
  #     better than off: the unit structurally cannot modify the transcripts it
  #     archives, which is the one mistake that would destroy the primaries. It
  #     holds for root too, which is what makes running as root acceptable here.
  #   ReadWritePaths = exactly the two trees this unit owns, and NOT /mnt/bulk.
  #     A root unit with the whole disk writable could reach the game libraries,
  #     the hashed point-in-time snapshot at transcripts-preserved-2026-10-15 and
  #     the .pre-subvol undo tree. None of those are this unit's business.
  #     /mnt/bulk itself does not need to be writable: the only parent that must
  #     be is the snapshots directory, because `btrfs subvolume snapshot` and
  #     `btrfs subvolume delete` both mutate a directory entry inside it, and
  #     that directory is already one of the two. The mount-point guard only
  #     reads.
  #
  #     The `-` prefix means "ignore if missing" (systemd.exec(5)). It is load
  #     bearing: the disk is mounted `nofail`, so when it is absent these paths
  #     do not exist, and without the prefix the unit would die in namespace
  #     setup with an opaque error instead of reaching the script's own mount
  #     check, which says plainly what is wrong.
  #   No User= - see the root note on the service below.
  hardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = "read-only";
    ReadWritePaths = [ "-${dest}" "-${snapDir}" ];
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [ "AF_UNIX" ];
    RestrictSUIDSGID = true;
    LockPersonality = true;
    SystemCallFilter = [ "@system-service" ];
  };
in
{
  # --- CLAUDE CODE TRANSCRIPT ARCHIVE (cycle-hq seats only) ---
  #
  # WHY. Claude Code deletes chat transcripts `cleanupPeriodDays` after their last
  # write. That default is 30, hardcoded, verified in the 2.1.300 bundle:
  #   cleanupPeriodDays: "Number of days to retain chat transcripts before
  #   automatic cleanup (default: 30). Minimum 1."
  # and the constant behind the `??` is literally `XOt=30`. No settings file on
  # Diana sets it. Those transcripts are the primaries of JL's quoted words - the
  # Operator seat cites 405 founder-quote cuts drawn from them - and unlike a game
  # library they cannot be re-downloaded.
  #
  # THE SWEEP IS PER SESSION, keyed on the main .jsonl's last write, not per file.
  # This was measured, and it matters because the per-file reading looks reassuring
  # and is wrong. Builder holds thousands of files older than 30 days and they all
  # sit inside ONE session folder (ecf23812) whose main file was last written
  # 2026-09-25: old agent files survive inside a YOUNGER session. Meanwhile the
  # genuinely old session went: cc53d49d, named as the primary of the 08-27..09-10
  # Operator cuts, is gone from the tree - 0 hits. The oldest surviving main file
  # is fff0323b at exactly 30 days, with the next at 23; it is still present only
  # because the sweep appears to run at session start and has not run since it
  # crossed. So the guillotine is armed and already took one session. ecf23812,
  # with everything nested under it, crosses on 2026-10-25.
  #
  # WHY A COPY AND NOT A LONGER RETENTION. Raising cleanupPeriodDays (minimum 1;
  # "use a large value", e.g. 3650) keeps the transcripts on the OS disk, the
  # single btrfs device shared by /, /home, /nix and /persist - the exact pressure
  # bulk-storage.nix exists to relieve. JL chose the copy.
  #
  # READ THIS BEFORE TRUSTING THE ARCHIVE. /mnt/bulk is the HP EX920 that threw
  # 29,611 media errors. bulk-storage.nix admits the game libraries here on the
  # explicit grounds that they are "large, read-mostly, and re-downloadable, so if
  # the erase did not in fact revive the drive, the loss is a Steam re-download
  # rather than data". Transcripts fail that test completely: they are the least
  # re-creatable data on this machine. This timer makes the archive survive
  # RETENTION, and the snapshots make it survive a bad write. Neither makes it
  # survive the DISK. A second leg off this box (S3, as hc-sync already does) is
  # still owed and is JL's call.
  systemd.services.transcript-archive = {
    description = "Archive cycle-hq Claude Code transcripts to the bulk disk";
    serviceConfig = hardening // {
      Type = "oneshot";

      # WHY ROOT, and why that is narrower than it sounds. Measured on this box as
      # skirmitch: `btrfs subvolume create` and `btrfs subvolume snapshot -r` both
      # succeed unprivileged, but `btrfs subvolume delete` does NOT - it needs root
      # or the user_subvol_rm_allowed mount option. Snapshot rotation is therefore
      # impossible as skirmitch. The alternative was adding that mount option to
      # bulk-storage.nix, which loosens the whole filesystem so a timer can rotate
      # its own snapshots; running this one sandboxed unit as root is the smaller
      # change. ProtectSystem=strict plus ReadWritePaths=/mnt/bulk means root here
      # can write to exactly one directory tree, and ProtectHome=read-only means it
      # cannot touch the transcripts it is archiving.
      #
      # A side benefit: rsync -a includes -o/-g, which silently did nothing as
      # skirmitch. As root the archive now really carries the source ownership.

      # A daily walk of ~48k files must never compete with anything JL is doing.
      Nice = 10;
      IOSchedulingClass = "idle";

      ExecStart = pkgs.writeShellScript "transcript-archive" ''
        set -euo pipefail

        btrfs=${pkgs.btrfs-progs}/bin/btrfs

        # A btrfs subvolume root always has inode 256. Every delete in this script
        # goes through this guard, because `btrfs subvolume` commands given a plain
        # directory fall back to the CONTAINING tree - the documented way to ask
        # for a snapshot rotation and get @home deleted instead.
        del_subvol() {
          local path="$1" ino
          ino=$(${pkgs.coreutils}/bin/stat -c %i "$path")
          if [ "$ino" != 256 ]; then
            echo "REFUSING to delete $path: inode $ino != 256, not a subvolume root." >&2
            return 1
          fi
          "$btrfs" subvolume delete "$path"
        }

        # 1. The bulk disk must REALLY be mounted. It is mounted `nofail`, so if the
        #    drive does not come back /mnt/bulk is an empty directory on the OS disk
        #    and an unguarded rsync would pour 13 GB per night onto root - the exact
        #    failure this disk was bought to prevent. Fail loudly rather than skip
        #    quietly: a unit in `systemctl --failed` gets noticed, a silent
        #    ConditionPathIsMountPoint skip does not.
        if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/bulk; then
          echo "REFUSING: /mnt/bulk is not a mount point - the bulk disk is absent." >&2
          echo "Archiving now would write to the OS disk instead. Nothing was copied." >&2
          exit 1
        fi

        # 2. Expand the glob ourselves. systemd does not run a shell, so an
        #    ExecStart with a bare `*` would hand rsync a literal asterisk.
        #    failglob makes a glob that matches nothing abort instead of doing that.
        shopt -s failglob
        set -- ${srcPrefix}*

        # 3. The framework fence, as a structure rather than a habit. Today the
        #    cycle-hq prefix cannot reach the four framework-named project folders,
        #    because none of them begins with "cycle-hq". This loop is here so that
        #    the day someone widens the prefix, the unit REFUSES instead of quietly
        #    archiving material that is fenced. EXCLUDE is the default and the
        #    scope of any wider archive is JL's to grant.
        for p in "$@"; do
          case "''${p,,}" in
            *framework*)
              echo "REFUSING: $p is inside the framework fence." >&2
              exit 1
              ;;
          esac
        done

        # Both trees must already exist. The unit no longer creates them, because
        # creating them would need /mnt/bulk writable, which is exactly the blast
        # radius we just gave up. They are one-time setup, and the archive has to
        # be a SUBVOLUME rather than a directory anyway, so this is the same class
        # of prerequisite either way. Refuse loudly with the commands rather than
        # quietly creating a directory on the wrong disk.
        for d in ${dest} ${snapDir}; do
          if [ ! -d "$d" ]; then
            echo "REFUSING: $d does not exist. One-time setup, as root:" >&2
            echo "  btrfs subvolume create ${dest}" >&2
            echo "  mkdir -p ${snapDir}" >&2
            exit 1
          fi
        done

        echo "archiving $# folder(s) to ${dest}"

        # 4. No --delete, ever: the archive has to outlive the source, which is the
        #    entire point. -a keeps times, permissions and (as root) ownership.
        #
        #    The exit code is captured rather than left to `set -e`, because rsync
        #    24 means "some source files vanished mid-transfer", which is NORMAL
        #    here - live sessions rotate files while we read them - and under a bare
        #    `set -e` it would fail the unit every single night. 0 and 24 are
        #    success; everything else must NOT be snapshotted, since a snapshot of a
        #    half-written archive is worse than no snapshot.
        rc=0
        ${pkgs.rsync}/bin/rsync -a --stats "$@" ${dest}/ || rc=$?
        if [ "$rc" = 24 ]; then
          echo "rsync exit 24: some source files vanished mid-transfer (expected on live sessions)."
        elif [ "$rc" != 0 ]; then
          echo "rsync FAILED with exit $rc - refusing to snapshot a partial archive." >&2
          exit "$rc"
        fi

        # 5. Immutability. A read-only snapshot per day is what protects against the
        #    failure rsync cannot: --delete is off, so the archive survives a
        #    DELETION at the source, but a source file overwritten by a TRUNCATED
        #    version would be copied over the good archived copy. Snapshots are
        #    reflinked, so each one costs only the extents that diverged.
        #
        #    Degrade in the safe direction: if the archive is not a subvolume yet,
        #    the copy above has already happened and is the critical function, so
        #    warn and finish green rather than fail and stop archiving.
        if [ "$(${pkgs.coreutils}/bin/stat -c %i ${dest})" != 256 ]; then
          echo "NOTE: ${dest} is not a btrfs subvolume, so no snapshot was taken." >&2
          echo "One-time conversion (no deletion; keeps the old copy renamed aside):" >&2
          echo "  btrfs subvolume create ${dest}.sv" >&2
          echo "  cp -a --reflink=always ${dest}/. ${dest}.sv/" >&2
          echo "  mv ${dest} ${dest}.pre-subvol && mv ${dest}.sv ${dest}" >&2
          ${pkgs.coreutils}/bin/du -sh ${dest}
          exit 0
        fi

        today=$(${pkgs.coreutils}/bin/date +%F)
        if [ -e ${snapDir}/"$today" ]; then
          # Re-running on the same day should leave today's snapshot matching the
          # archive as it now stands, so replace rather than skip.
          del_subvol ${snapDir}/"$today"
        fi
        "$btrfs" subvolume snapshot -r ${dest} ${snapDir}/"$today"
        echo "snapshot: ${snapDir}/$today"

        # 6. Rotation: keep the 14 most recent, plus the newest snapshot of each
        #    calendar month. The current month's keeper therefore advances until the
        #    month ends, which is intended - a month is only finished once.
        #    Snapshots are named YYYY-MM-DD, so a lexical sort is a date sort.
        keep=$(
          {
            ${pkgs.coreutils}/bin/ls -1 ${snapDir} | ${pkgs.coreutils}/bin/sort -r | ${pkgs.coreutils}/bin/head -14
            ${pkgs.coreutils}/bin/ls -1 ${snapDir} | ${pkgs.coreutils}/bin/sort -r \
              | ${pkgs.gawk}/bin/awk -F- '!seen[$1"-"$2]++'
          } | ${pkgs.coreutils}/bin/sort -u
        )
        for s in $(${pkgs.coreutils}/bin/ls -1 ${snapDir}); do
          if ! echo "$keep" | ${pkgs.gnugrep}/bin/grep -qx "$s"; then
            echo "rotating out ${snapDir}/$s"
            del_subvol ${snapDir}/"$s"
          fi
        done

        ${pkgs.coreutils}/bin/du -sh ${dest}
        echo "snapshots kept: $(${pkgs.coreutils}/bin/ls -1 ${snapDir} | ${pkgs.coreutils}/bin/wc -l)"
      '';
    };
  };

  systemd.timers.transcript-archive = {
    description = "Daily cycle-hq transcript archive";
    wantedBy = [ "timers.target" ];
    # 04:00 is free: hc-backup holds 03:30 and the postgres drop holds 04:30.
    # Persistent= is real here (OnCalendar=) and genuinely works, because
    # /var/lib/systemd/timers is persisted in hosts/diana/impermanence.nix - a
    # day with Diana switched off is caught up on the next boot rather than
    # silently skipped.
    timerConfig = { OnCalendar = "04:00"; Persistent = true; };
  };
}
