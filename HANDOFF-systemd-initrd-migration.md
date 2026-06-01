# Handoff — systemd-initrd migration (impermanence root wipe)

**Date:** 2026-06-01 · **Host:** Diana · **Repo:** `~/nix-config` (flake)
**Status:** Migration **deferred**, system **stable & clean** on scripted initrd. No data ever at risk.

This file is self-contained: read only this to resume. Companion notes:
- Auto-memory: `~/.claude/projects/-home-skirmitch-nix-config/memory/project_systemd_initrd_migration_2026_05_31.md`
- Original plan: `~/.claude/plans/vectorized-frolicking-star.md`
- Cleanup tool: `~/cleanup-old-roots.sh` (defaults to dry run; `--apply` to delete)

---

## TL;DR

We tried to migrate the impermanence "erase your darlings" root wipe from the deprecated
scripted-initrd hook (`boot.initrd.postDeviceCommands`, **removed in NixOS 26.11**) to a
systemd-initrd service. Two attempts; the second **hard-hung the boot**. We **reverted to the
proven scripted-initrd setup** (stable, unchanged for months), then cleaned up months of cruft.

**You are currently on:** gen 128 = scripted initrd, `/` correctly on `@root`, everything healthy.
**Deadline:** scripted initrd works until **26.11** (you're on 26.05) — months of runway, no rush.

**The migration is the only unfinished goal. Everything else is clean.** The cosmetic
`Scripted initrd is deprecated` warning on rebuild is expected and is the only loose end.

---

## Why migrate at all

NixOS 26.05 made systemd-initrd the default and **deprecated scripted initrd, scheduled for
REMOVAL in 26.11**. Our root wipe uses `boot.initrd.postDeviceCommands`, which is a
scripted-initrd-only hook. When 26.11 lands, that hook stops existing and the wipe silently
stops running (impermanence dies) unless we've migrated it to a systemd-initrd service.

---

## System facts (everything a fresh session needs)

- **One btrfs filesystem**, UUID `3e5658eb-f316-490b-855c-9efce6e920eb`.
  - Device node **varies across boots** (`nvme2n1p2` ↔ `nvme0n1p2`) — **always use by-uuid**, never the device path.
- **Subvolumes (top-level / subvolid 5):**
  - `@root` → `/`  (ephemeral; wiped & recreated every boot)
  - `@root-blank` → pristine template, UUID `714582d8-b1fb-7946-850b-8facf72d6cfc`
  - `@home` → `/home`  (persisted, `neededForBoot = true`)
  - `@persist` → `/persist`  (persisted, `neededForBoot = true`, impermanence bind-mount source)
  - `@nix` → `/nix`,  `@log` → `/var/log`
  - `old_roots/` → archive dir (now empty)
- **`@root`'s nested subvolumes:** just `/srv` and `/var/tmp` (NixOS makes these subvolumes).
  This is important: deleting `@root` is only ~3 quick btrfs ops — it is **NOT heavy**.
- **No LUKS, no swap, no resume/hibernate, no plymouth.** Clean migration surface.
- **Kernel pinned to 7.0.5** in `hosts/diana/default.nix` (MT7921U BT regression in 7.0.8+). Unrelated to initrd.
- **Hosts:** `diana` (this machine, real) and `lenovo` (scaffold — `hardware.nix` is commented-out
  `REPLACE-ME`; it does NOT evaluate to a bootable system, fails on "no root filesystem", which is
  pre-existing and unrelated).
- **Relevant files:**
  - `modules/system/boot.nix` — shared by both hosts; holds `boot.initrd.systemd.enable` (currently `false`).
  - `hosts/diana/impermanence.nix` — the wipe (currently scripted `postDeviceCommands`) + `environment.persistence`.
  - `hosts/lenovo/impermanence.nix` — same shape with `REPLACE-ME` placeholders.

### Verified nixpkgs / systemd-initrd facts (don't re-derive — checked against locked 26.05 source)

- **Assertion:** setting `boot.initrd.postDeviceCommands` (or `postMountCommands`, `preDeviceCommands`,
  `preLVMCommands`, `postResumeCommands`, `network.postCommands`) to a **non-empty** value while
  `boot.initrd.systemd.enable = true` **fails evaluation**
  (`nixos/modules/system/boot/systemd/initrd.nix:~496`). So the old hook MUST be removed in the **same
  commit** that flips systemd-initrd on. Because `boot.nix` is shared, **both** hosts' `impermanence.nix`
  must be migrated together or `nix flake check` breaks.
- **Binaries already in systemd initrd by default:** `btrfs` (btrfs-progs, auto-added since root is btrfs),
  `date`, `mv`, `mkdir`, `mount`, `umount` (coreutils + util-linux). **No `initrdBin` additions needed.**
- **`.script` runs under bash** with `set -e` already injected by nixpkgs (`systemd-lib.nix`).
- **Root mount unit is `sysroot.mount`**; all neededForBoot subvols mount at `/sysroot/*`. btrfs allows
  concurrent subvol mounts of one device, so mounting the top-level at `/mnt` in the service is safe.
- **`requiredBy` is realized as a `.requires` symlink** (so it won't show in the unit's `[Unit]` text — that's normal).
- **Escaped device-unit name** (from `systemd-escape -p --suffix=device /dev/disk/by-uuid/<UUID>`):
  `dev-disk-by\x2duuid-3e5658eb\x2df316\x2d490b\x2d855c\x2d9efce6e920eb.device`
  (in a Nix `''...''` string write each `\` doubled: `\\x2d`). Regenerate to be safe.

---

## What we tried & what happened (chronology)

1. **Attempt 1 — systemd initrd + "move-aside" rollback (gen 126).**
   Unit moved `@root` → `old_roots/@root_<ts>`, then `snapshot @root-blank @root`.
   **Booted fine, BUT `/` ended up mounted on the *moved* subvolume under `old_roots/`** instead of `@root`.
2. **Attempt 2 — systemd initrd + "delete-and-recreate" rollback (gen 127).**
   Unit recursively deletes `@root` (+children), then `snapshot @root-blank @root`; also added
   `before = [ "sysroot.mount" "initrd-root-fs.target" ]`.
   **Hard-hung in early stage-1 initrd** — black screen, frozen keyboard (numlock dead), no journal
   survived (hung before journal flush). Recovered by selecting an older generation.
3. **Reverted** all 3 files to committed scripted-initrd state (`git checkout`), `nixos-rebuild boot` +
   reboot → **gen 128 = scripted initrd, stable, `/` on `@root`.**
4. **Cleaned up:** purged all **97** accumulated `old_roots` (each had nested `/srv`+`/var/tmp`, which is
   why plain deletes failed "Directory not empty"); deleted bad boot entries **gen 126 & 127**
   (kept gen 125 as a scripted fallback).

---

## Root-cause diagnosis (CORRECTED — important)

My first theory (recursive delete choking on the 280-subvolume bloat) was **wrong** — the dry run proved
`@root` has only 2 tiny nested subvols, so deleting it is trivial even on a bloated fs.

**The real problem: `before = [ "sysroot.mount" ]` did NOT reliably serialize the rollback before the
root mount.** Evidence: Attempt 1 (move-aside) booted with `/` parked on the *moved* subvolume — which can
only happen if `sysroot.mount` raced ahead and mounted `@root` **before** the rollback's `mv`.
- With **move-aside**, renaming a subvolume that's already mounted is harmless → it boots (just wrong layout).
- With **delete-and-recreate**, the same race means the rollback tried to **delete the subvolume the system
  was actively mounting as `/`** → corrupt/blocked state → **hard hang**. The added
  `before = initrd-root-fs.target` may have compounded it.

So the core thing to fix on the redo is **the ordering race**, not the delete logic or the cruft.

---

## Current state (verified 2026-06-01)

- Booted = `gen 128` = `zbs8xfl8…-nixos-system-Diana` = the reverted scripted config (booted == current).
- `findmnt /` → `subvol=/@root` ✅ (not old_roots).
- Scripted initrd (no `(initrd)` phase in `systemd-analyze`), no rollback unit, **no failed units**.
- `old_roots/` empty (0). Will re-grow ~1 entry/boot under scripted initrd — re-run `~/cleanup-old-roots.sh` occasionally.
- Generations present: 128 (current), 125 & 124 (older scripted fallbacks). 126 & 127 deleted.
- `git status`: the 3 migration files are **clean** (reverted). Only unrelated `result` (M) and `resume` (??) show.
- Persistence intact (`~/.ssh`, `~/Documents`, `~/nix-config`, …).

---

## The plan to redo it SAFELY (when ready, before 26.11)

**Pre-flight (do NOT skip):**
1. Ensure a known-good **scripted** generation is the *previous* boot entry as a fallback. gen 125 may be
   GC'd by then (`nix.gc` deletes >7d) — so first run `sudo nixos-rebuild boot --flake ~/nix-config#diana`
   on the *current scripted* config to mint a fresh scripted fallback generation.
2. `old_roots` is already clean — keep it that way (re-run the cleanup script if it's grown).
3. Take instant read-only safety snapshots before the first systemd-initrd reboot:
   ```
   sudo mount -o subvolid=5 /dev/disk/by-uuid/3e5658eb-f316-490b-855c-9efce6e920eb /tmp/tl
   sudo btrfs subvolume snapshot -r /tmp/tl/@home    /tmp/tl/@home-backup
   sudo btrfs subvolume snapshot -r /tmp/tl/@persist /tmp/tl/@persist-backup
   sudo umount /tmp/tl
   ```

**The change (all in ONE commit):**
- `modules/system/boot.nix`: `boot.initrd.systemd.enable = true;`
- `hosts/diana/impermanence.nix` & `hosts/lenovo/impermanence.nix`: replace `postDeviceCommands` with the
  service below. (lenovo keeps `REPLACE-ME` placeholders; it only needs to eval, not boot.)

**Candidate corrected rollback unit (delete-and-recreate, light, fail-fast):**
```nix
boot.initrd.systemd.services.rollback = {
  description = "Rollback btrfs @root to a pristine @root-blank snapshot";
  wantedBy   = [ "initrd.target" ];
  after      = [ "dev-disk-by\\x2duuid-3e5658eb\\x2df316\\x2d490b\\x2d855c\\x2d9efce6e920eb.device" ];
  requires   = [ "dev-disk-by\\x2duuid-3e5658eb\\x2df316\\x2d490b\\x2d855c\\x2d9efce6e920eb.device" ];
  before     = [ "sysroot.mount" ];          # DROP the initrd-root-fs.target add from attempt 2
  requiredBy = [ "sysroot.mount" ];           # failed rollback -> emergency, not silent-wrong
  unitConfig.DefaultDependencies = "no";
  serviceConfig = {
    Type = "oneshot";
    TimeoutStartSec = "180s";                 # a STALL fails to emergency instead of hanging forever
  };
  script = ''
    set -euo pipefail
    mkdir -p /mnt
    mount -t btrfs -o subvol=/ /dev/disk/by-uuid/3e5658eb-f316-490b-855c-9efce6e920eb /mnt

    delete_subvolume_recursively() {
      IFS=$'\n'
      for child in $(btrfs subvolume list -o "$1" | cut -f9- -d' '); do
        delete_subvolume_recursively "/mnt/$child"
      done
      btrfs subvolume delete "$1"
    }
    if [ -e /mnt/@root ]; then delete_subvolume_recursively /mnt/@root; fi
    btrfs subvolume snapshot /mnt/@root-blank /mnt/@root
    umount /mnt
  '';
};
```

**THE OPEN PROBLEM TO SOLVE FIRST = the ordering race.** The canonical community configs (Misterio77 /
nixos-impermanence) claim `before = [ "sysroot.mount" ]` is sufficient — yet here `sysroot.mount` raced
ahead. Investigate WHY before trusting it again. Likely angle: the `systemd-fstab-generator` pulls
`sysroot.mount` in via `initrd-root-fs.target` early. Options to try:
- Add a **debug shell** to observe ordering live without a blind hang: kernel param `rd.systemd.debug_shell`
  (console on tty9) and/or `boot.initrd.systemd.emergencyAccess = true`. Then read
  `systemd-analyze --root /  ...` / `journalctl` from inside.
- Confirm in the *generated* units that `sysroot.mount` actually has `After=rollback.service` /
  `Requires=rollback.service` (the `.requires` symlink) — inspect the built initrd, not just `.text`.
- Consider whether `sysroot.mount` needs an explicit `After=rollback.service` set from our side, or whether
  the service should also be ordered against `initrd-root-device.target`.
- **Best: prove it in a VM** with a replicated subvol layout (`nixos-rebuild build-vm`) before touching the
  daily driver — a hung initrd leaves no logs, so live trial-and-error is painful.

**Validate before reboot:**
```
nix flake check                                   # both hosts eval (lenovo still fails on its REPLACE-ME root fs — pre-existing)
nix eval --raw '.#nixosConfigurations.diana.config.boot.initrd.systemd.units."rollback.service".text'
```
Then `sudo nixos-rebuild boot` (NOT switch), drop a sentinel `sudo touch /WIPE-TEST`, reboot.

**Success looks like:** `findmnt /` shows `subvol=/@root` (NOT old_roots); `ls /WIPE-TEST` gone;
`journalctl -b | grep -i rollback` clean; no failed units; `/home` `/persist` intact.

**If it hangs again:** select the scripted fallback generation at the boot menu → back to safe.
Then flip `boot.initrd.systemd.enable = false` and rebuild. Data is never at risk (`@home`/`@persist`
are separate subvolumes the rollback never touches).

---

## Handy commands & artifacts

- **Cleanup accumulated old_roots** (safe, dry-run default):
  `sudo bash ~/cleanup-old-roots.sh`  then  `sudo bash ~/cleanup-old-roots.sh --apply`
- **Which generation am I on:** `readlink -f /run/booted-system`
- **List generations:** `ls -1dt /nix/var/nix/profiles/system-*-link`
- **Delete bad generations from the menu:**
  `sudo nix-env -p /nix/var/nix/profiles/system --delete-generations <N…> && sudo /run/current-system/bin/switch-to-configuration boot`
- **Regenerate escaped device-unit name:**
  `systemd-escape -p --suffix=device /dev/disk/by-uuid/3e5658eb-f316-490b-855c-9efce6e920eb`

---

## Notes

- `boot`, not `switch`, on initrd/persist changes (switch's daemon re-exec has broken persist binds before).
- Keep at least one **scripted** generation reachable until the systemd-initrd version is proven.
- This file is untracked in git (won't affect builds). Delete it once the migration is done.
