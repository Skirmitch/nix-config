#!/usr/bin/env python3
"""
tmp-sweep - reclaim leaked `nix shell` temp dirs from /tmp.

WHY THESE LEAK
    A gate runs the test suite inside `nix shell`, which sets
    TMPDIR=/tmp/nix-shell.XXXXXX. pytest's tmp_path factory honours TMPDIR, so
    `pytest-of-skirmitch/pytest-N` is created INSIDE that throwaway dir - about
    1.1 GB per run with 24 xdist workers. pytest's "keep the last 3" retention
    only prunes within a single base, and every run gets a fresh base, so it
    never fires. `nix shell` removes its dir only on a clean exit, so every
    killed or timed-out run strands the whole 1.1 GB. 2,335 of them accumulated
    197 GiB in six days.

    The real fix is upstream of this tool: give pytest a stable --basetemp
    outside TMPDIR. This only cleans up what already leaked.

SAFETY - it refuses rather than guesses
    * only /tmp/nix-shell.* , maxdepth 1, real directories, never symlinks
    * skips any dir a live process has as its cwd OR holds an open fd under
    * skips any dir whose NEWEST mtime anywhere in the subtree is too recent
      (the top-level mtime alone is NOT enough: a long test writes deep inside
      while the top dir's mtime stays old)
    * dry-run by default; --delete is required to remove anything

USAGE
    tmp-sweep                 # inventory only
    tmp-sweep --delete        # actually remove the orphans
    tmp-sweep --min-age 360   # be more conservative (minutes, default 120)
"""

import argparse
import glob
import os
import shutil
import sys
import time

PREFIX = "/tmp/nix-shell."


def held_paths():
    """Every /tmp/nix-shell.* dir a live process is using, via cwd or an open
    fd. A dir can be in use without being anyone's cwd, so check both."""
    held = set()
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        for probe in ("cwd", "exe"):
            try:
                t = os.readlink("/proc/%s/%s" % (pid, probe))
                if t.startswith(PREFIX):
                    held.add(t.split("/")[2])
            except OSError:
                pass
        fddir = "/proc/%s/fd" % pid
        try:
            for fd in os.listdir(fddir):
                try:
                    t = os.readlink(os.path.join(fddir, fd))
                except OSError:
                    continue
                if t.startswith(PREFIX):
                    held.add(t.split("/")[2])
        except OSError:
            continue
    return held


def walk_stats(path):
    """(bytes, newest_mtime) over the whole subtree, symlinks never followed."""
    size = 0
    newest = 0.0
    for root, dirs, files in os.walk(path, onerror=lambda e: None,
                                     followlinks=False):
        try:
            newest = max(newest, os.lstat(root).st_mtime)
        except OSError:
            pass
        for name in files:
            try:
                st = os.lstat(os.path.join(root, name))
            except OSError:
                continue
            size += st.st_size
            if st.st_mtime > newest:
                newest = st.st_mtime
    return size, newest


def main():
    ap = argparse.ArgumentParser(prog="tmp-sweep")
    ap.add_argument("--delete", action="store_true")
    ap.add_argument("--min-age", type=int, default=120,
                    help="minutes of quiet required before a dir is eligible")
    a = ap.parse_args()

    now = time.time()
    held = held_paths()
    cutoff = a.min_age * 60

    orphans, kept = [], []
    for d in sorted(glob.glob(PREFIX + "*")):
        if os.path.islink(d) or not os.path.isdir(d):
            continue
        base = os.path.basename(d)
        size, newest = walk_stats(d)
        quiet = now - newest if newest else 1e9
        if base in held:
            kept.append((d, size, "in use by a live process"))
        elif quiet < cutoff:
            kept.append((d, size, "active %.0f min ago" % (quiet / 60)))
        else:
            orphans.append((d, size, quiet))

    o_bytes = sum(s for _, s, _ in orphans)
    k_bytes = sum(s for _, s, _ in kept)

    print("tmp-sweep  -  %s" % ("DELETING" if a.delete else "inventory only"))
    print("  eligible : %5d dirs  %8.1f GiB   (quiet > %d min, nothing holds them)"
          % (len(orphans), o_bytes / 2**30, a.min_age))
    print("  protected: %5d dirs  %8.1f GiB" % (len(kept), k_bytes / 2**30))
    for d, s, why in kept[:10]:
        print("       keep %-28s %7.2f GiB  - %s"
              % (os.path.basename(d), s / 2**30, why))

    if not a.delete:
        print("\n  nothing removed. re-run with --delete to reclaim %.1f GiB"
              % (o_bytes / 2**30))
        return 0

    freed = failed = 0
    for d, s, _ in orphans:
        # re-check immediately before unlinking: the inventory walk takes
        # minutes, and a new run may have claimed this dir since.
        if os.path.basename(d) in held_paths():
            print("  SKIP (became active) %s" % d)
            continue
        try:
            shutil.rmtree(d)
            freed += s
        except OSError as e:
            failed += 1
            print("  FAILED %s: %s" % (d, e))
    print("\n  reclaimed %.1f GiB, %d failures" % (freed / 2**30, failed))
    print("  NOTE: btrfs keeps the chunks ALLOCATED. `btrfs filesystem usage /`")
    print("  will still show ~0 unallocated until a balance returns them, so")
    print("  metadata cannot grow yet even though df improved.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
