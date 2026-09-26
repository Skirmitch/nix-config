{ ... }:
let
  # The bulk disk, created 2026-09-26 (HP EX920, nvme1n1p1, btrfs, subvol @games).
  bulkUuid = "8e98d07d-2bff-471d-b427-03f4258acc79";
in
{
  # --- BULK STORAGE ON THE SECOND NVMe ---
  #
  # /, /home, /nix, /persist and /var/log are all ONE btrfs device (nvme2n1p2). That is
  # why a runaway agent scratch can stop every session on the box: there is no partition
  # between the thing that grows and the operating system. On 2026-09-26 root reached
  # 66 GB free falling 1.8 GB/min, about 35 minutes from a full root.
  #
  # Moving the two game libraries here frees ~360 GB on that device (Steam 212 G, the
  # anime-game-launcher 148 G of which 145 G is Genshin), taking root from ~313 GB free
  # to ~673 GB. Space is not itself a bound — the seats get a quota for that — but it
  # removes the standing pressure that made every incident this month urgent.
  #
  # WHY THIS DISK, given the history. nvme1n1 is the HP SSD EX920 that threw 29,611
  # media errors and killed the old Gentoo install. The diagnosis was corrected: heat
  # from a dead laptop fan caused NAND charge decay, NOT wear — the spare pool is
  # untouched at 100% and endurance is 8% used — so a full erase resets the cells, and
  # it was erased with `nvme format --ses=1` on 2026-09-26. There is a standing rule in
  # memory never to relocate anything here. Game libraries are the deliberate exception
  # and the right one: they are large, read-mostly, and re-downloadable, so if the erase
  # did not in fact revive the drive, the loss is a Steam re-download rather than data.
  #
  # WHY btrfs AND NOT ext4, on a drive we do not fully trust: btrfs checksums every
  # block and verifies it on read. If this drive starts returning bad data, btrfs says
  # so (`btrfs device stats`, a scrub) instead of handing the corruption to Proton.
  # That is a continuous surface test on exactly the bytes we care about, which is
  # worth more than a one-off badblocks run that only describes the drive an hour ago.
  # CoW is deliberately left ON: `nodatacow` would disable checksumming, and on a
  # read-mostly game library verification is worth more than the fragmentation it costs.
  #
  # WHY A SUBVOLUME AND NOT A SECOND PARTITION: `@games` shares the whole pool, so if
  # we later decide seat scratch belongs here too it is another subvolume, not a
  # repartition. Nothing has to be sized correctly today.
  fileSystems."/mnt/bulk" = {
    device = "/dev/disk/by-uuid/${bulkUuid}";
    fsType = "btrfs";
    # nofail: a drive with this history may not come back one day, and that must
    # degrade Steam rather than block the boot.
    options = [ "subvol=@games" "nofail" "x-systemd.device-timeout=10s" ];
  };

  # Seat scratch, on the bulk disk rather than the OS disk.
  #
  # This is the one layer that actually ENFORCES. A hostile review (73 agents) established
  # that the hooks, the lint and guard.py are tripwires: the 2026-09-26 incident ran
  # `python3 mx_run3.py`, which contains no copy verb, and the copying was `git clone
  # --shared` + `git checkout` inside a grandchild process. A PreToolUse matcher sees none
  # of that, and `nix shell ... -c prlimit --` - which the seat's own briefs mandate -
  # turns a DENY into an ALLOW on the rules that do exist.
  #
  # It is on THIS disk, not the OS one, because of metadata. A btrfs qgroup counts LOGICAL
  # bytes; metadata here is DUP (ratio 2.00). Measured: a reflinked `cp -a` of 65,767
  # files adds 0 MiB of data and 66 MiB of METADATA, 912 B per inode. On the OS filesystem
  # metadata exhausts while a data-sized quota has not fired, and metadata ENOSPC aborts
  # the transaction and takes the filesystem READ-ONLY - every session and the desktop
  # stop. Physical separation is what bounds that; a quota on the same device does not.
  #
  # Per-seat subvolumes underneath carry `btrfs quota enable --simple` limits (32G
  # operator, 20G builder). Simple qgroups account by extent lifetime rather than backref
  # walks, which answers the unmeasured-CPU objection to quotas. The OS filesystem, with
  # its parked roots, never gets quotas.
  fileSystems."/mnt/scratch" = {
    device = "/dev/disk/by-uuid/${bulkUuid}";
    fsType = "btrfs";
    options = [ "subvol=@scratch" "nofail" "x-systemd.device-timeout=10s" ];
  };

  # Bind the two libraries into place.
  #
  # These REPLACE the impermanence entries for the same paths — both were removed from
  # hosts/diana/impermanence.nix in the same commit. Leaving them in would be the
  # silent failure here: impermanence would bind /persist over the top, you would still
  # see the old data, Steam would still work, and NOT ONE BYTE would have been freed.
  fileSystems."/home/skirmitch/.local/share/Steam" = {
    device = "/mnt/bulk/Steam";
    fsType = "none";
    options = [ "bind" "nofail" ];
    depends = [ "/mnt/bulk" "/home" ];
  };

  fileSystems."/home/skirmitch/.local/share/anime-game-launcher" = {
    device = "/mnt/bulk/aagl";
    fsType = "none";
    options = [ "bind" "nofail" ];
    depends = [ "/mnt/bulk" "/home" ];
  };

  # NOT moved, on purpose:
  #   .steam              44 K  — symlinks and config only; stays persisted
  #   Games               12 G  — the ON1 Photo RAW Wine prefix, which holds the licence
  #                               activation and catalog. Moving it risks the activation
  #                               for 12 GB; not worth it.
  #   .local/share/lutris 1.9 G — the runners and game DB that point INTO Games
}
