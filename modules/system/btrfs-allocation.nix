{ pkgs, ... }:
let
  btrfs = "${pkgs.btrfs-progs}/bin/btrfs";
  findmnt = "${pkgs.util-linux}/bin/findmnt";
in
{
  # --- Give btrfs its chunks back on / ---
  #
  # THE PROBLEM (measured 2026-10-23, after reclaiming 189 GiB of leaked /tmp):
  #
  #   Device size        930.51 GiB
  #   Device allocated   930.51 GiB
  #   Device unallocated      1.00 MiB     <-- this is the whole problem
  #   Data,single        898.50 GiB alloc / 626.28 GiB used
  #   Metadata,DUP        16.00 GiB alloc /   8.35 GiB used  (32 GiB of device)
  #
  # btrfs allocates the raw device into CHUNKS, and a chunk's type - Data,
  # Metadata or System - is fixed when it is created and never changes. So the
  # 272 GiB of free space sitting inside Data chunks can never serve metadata.
  # With 1.00 MiB unallocated, no new chunk of ANY type can be created, which
  # caps metadata at 16 GiB permanently.
  #
  # Metadata exhaustion is not an ordinary "disk full". btrfs is copy-on-write,
  # so recording a change - INCLUDING a deletion - requires allocating new
  # metadata first. Running out is a deadlock: `rm` needs the resource that is
  # gone. And an ENOSPC during a transaction commit cannot be retried, so btrfs
  # aborts the transaction and flips the filesystem READ-ONLY to protect it.
  # That stops every agent seat, the desktop and the journal at once. The
  # 512 MiB global reserve exists only to keep one commit completable so there
  # is a chance to recover.
  #
  # Allocation tracks the HIGH-WATER MARK, not current use, because the kernel
  # never returns an emptied chunk on its own unless dynamic_reclaim is on.
  # Verified on this pool: dynamic_reclaim = 0 on all three space types and
  # reclaim_count = 0 - it has never once reclaimed a chunk in its life. That is
  # why freeing 189 GiB moved df from 93% to 71% and left unallocated at exactly
  # 1.00 MiB. The data went; the carving did not.
  #
  # /mnt/bulk does NOT have this problem (466.84 GiB unallocated), so both units
  # below are scoped to / deliberately.

  # Prevention, from now on: let the kernel hand back mostly-empty DATA chunks
  # by itself, so the high-water mark stops being permanent.
  #
  # DATA ONLY, on purpose. Enabling this for metadata would let the kernel
  # reclaim metadata chunks too, shrinking exactly the headroom this module
  # exists to protect.
  #
  # WHY THIS UNIT HAS TO EXIST AT ALL: these sysfs knobs are NOT persistent -
  # they reset to 0 on unmount and on every reboot. A one-off `echo 1 >` would
  # silently lapse at the next boot, which is the whole reason this is a unit
  # wired to multi-user.target rather than something done by hand once.
  #
  # AND WHY IT DOES NOT FIX THE EXISTING 272 GiB: reclaim is EDGE-TRIGGERED by
  # default. A block group only becomes a candidate when a free operation drops
  # its usage, and only a COMPLETELY empty one is reclaimed automatically. The
  # data chunk size here is 10 GiB (allocation/data/chunk_size), so a chunk
  # emptying entirely essentially never happens once files are scattered across
  # them - which is why reclaim_count read 0 for this pool's whole life and why
  # unallocated stayed at 1.00 MiB after the knob went on. Only a balance forces
  # the consolidation. Prevention and cure are genuinely separate jobs here.
  #
  # There is a third knob, `periodic_reclaim`, which makes the kernel sweep
  # existing block groups instead of waiting to be nudged. Left at 0
  # deliberately: it would do balance-shaped I/O at times nobody chose, on the
  # disk the stall probe already shows as this machine's bottleneck (io stall
  # 24-48x the cpu stall). The manual balance below gets the same result under
  # control. Revisit if the probe ever says / has I/O headroom to spare.
  #
  # Note `bg_reclaim_threshold` is NOT set here: dynamic_reclaim computes its
  # own threshold and the two are documented as mutually exclusive.
  systemd.services.btrfs-dynamic-reclaim = {
    description = "Enable btrfs dynamic chunk reclaim for data on /";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    script = ''
      uuid=$(${findmnt} -no UUID /)
      knob="/sys/fs/btrfs/$uuid/allocation/data/dynamic_reclaim"
      # Fail LOUDLY rather than silently no-op. If a future kernel renames or
      # drops this knob, a quiet skip would remove the only thing preventing the
      # allocation problem from rebuilding, with no symptom until / wedges again.
      # A unit in `systemctl --failed` is the cheapest possible tripwire.
      if [ ! -e "$knob" ]; then
        echo "btrfs-dynamic-reclaim: $knob does not exist."
        echo "The kernel knob moved or went away - re-check before assuming"
        echo "chunk reclaim still happens. See modules/system/btrfs-allocation.nix"
        exit 1
      fi
      echo 1 > "$knob"
      echo "btrfs-dynamic-reclaim: data dynamic_reclaim = $(cat "$knob") on $uuid"
    '';
  };

  # Cure, for the chunks already carved: fired BY HAND, never on a timer.
  #
  #     sudo systemctl start btrfs-rebalance-root
  #     journalctl -fu btrfs-rebalance-root
  #
  # No `wantedBy` and no timer, by design. A balance rewrites real data, so it
  # is heavy sequential I/O and must be a deliberate choice about when the box
  # is free - not something that ambushes a working session. The 189 GiB sweep
  # is what makes it cheap: there are now 272 GiB of free space inside the data
  # chunks for extents to be packed into, where before there were 72.
  #
  # The three passes escalate on purpose. -dusage=0 only deletes chunks that are
  # already completely empty and is close to instant; most of the win usually
  # lands there. Each later pass rewrites progressively fuller chunks and costs
  # progressively more I/O, so running them in this order means the cheap wins
  # are banked before any real work starts, and the job can be interrupted
  # between passes without losing them.
  systemd.services.btrfs-rebalance-root = {
    description = "Return empty/sparse btrfs data chunks on / to unallocated";
    serviceConfig = {
      Type = "oneshot";
      # A balance on a 900 GiB filesystem can run for a long time; the default
      # start timeout would kill it mid-pass.
      TimeoutStartSec = "infinity";
      # If it IS started during work, it must lose every race for the disk.
      Nice = 19;
      IOSchedulingClass = "idle";
      CPUWeight = 1;
    };
    script = ''
      echo "=== BEFORE ==="
      ${btrfs} filesystem usage /
      for u in 0 20 50; do
        echo "=== balance pass -dusage=$u ==="
        ${btrfs} balance start -dusage=$u / || exit 1
        echo "unallocated now: $(${btrfs} filesystem usage / \
          | ${pkgs.gnugrep}/bin/grep -F 'Device unallocated')"
      done
      echo "=== AFTER ==="
      ${btrfs} filesystem usage /
    '';
  };
}
