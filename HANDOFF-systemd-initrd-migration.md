# Handoff — systemd-initrd migration (impermanence root wipe)

**Updated:** 2026-09-24 · **Host:** Diana · **Repo:** `~/nix-config` (flake)
**Status:** Analysed, planned, **build-verified by evaluation, NOT yet applied.** Waiting only on a reboot window.
System is stable on scripted initrd; nothing in the working tree is staged.

This file is self-contained. Companion notes:
- Auto-memory: `~/.claude/projects/-home-skirmitch-nix-config/memory/reference_systemd_initrd_rollback_rerun.md` (the mechanism)
- Auto-memory: `.../project_systemd_initrd_migration_2026_05_31.md` (the May attempt log, now annotated as superseded)
- Cleanup tool: `~/cleanup-old-roots.sh` (dry run by default; `--apply` to delete)

> **⚠ The 2026-06-01 version of this file blamed an ordering race. That was wrong.** It is corrected below.
> Do not re-derive the old theory; it is refuted by the evidence the file itself recorded.

---


## ⛔ PREREQUISITE (added 2026-09-25): there must be at least 2 parked roots

The 2026-09-25 disk reclamation ran `~/cleanup-old-roots.sh --apply`. That script has **no retention** —
line 55 loops over `old_roots/@root_*` unconditionally — so it deleted **all 57** parked roots.
**Diana currently has ZERO.**

Those roots are the forensic record for this exact migration. Both May 2026 failures were diagnosed by
inspecting what the wipe had done to the parked roots; without them a third failure is unexplainable.

`hosts/diana/impermanence.nix` now carries a retention loop that keeps the **2 newest** roots, so the
net rebuilds on its own: one root after the next normal reboot, two after the one following.

**Gate before Phase 1:**

```
sudo btrfs subvolume list / | grep -oP 'old_roots/@root_[0-9_-]+$' | sort -u | wc -l   # must be >= 2   (count DISTINCT roots: a plain `grep -c 'old_roots/@root_'`
#                 counts THREE lines per parked root, because each carries
#                 nested srv and var/tmp subvolumes, so it reads 3 after a
#                 single reboot and passes this gate with ONE rollback root.)
```

Note the retention lives in the *initrd* script. It does not apply to the manual cleanup script, and if
the migration replaces `boot.initrd.postDeviceCommands` with a systemd unit, **the retention loop must be
carried into that unit** (together with `RemainAfterExit = true`) or the old_roots leak returns.

## TL;DR

The impermanence "erase your darlings" wipe lives in `boot.initrd.postDeviceCommands`, a scripted-initrd-only
hook. Migrating it to systemd initrd failed twice in May 2026 — once leaving `/` mounted on a subvolume parked
under `old_roots/`, once hard-hanging stage 1 with no logs.

**Root cause, found 2026-09-24: the rollback unit ran TWICE.** Not an ordering race. Fix is one line:
`serviceConfig.RemainAfterExit = true`.

**There is no deadline.** Scripted initrd is *not* removed on the current pin — `stage-1.nix:733` still only
emits a warning, tracking issue #287308 is open with its removal box unticked, and no removal PR is merged.
`boot.initrd.systemd.enable = false` remains a working escape hatch. The May attempt was rushed by a
deadline that did not bind.

---

## Root cause (corrected — this is the whole story)

A `Type = "oneshot"` unit that is `requiredBy` a mount **runs a second time** unless it sets
`RemainAfterExit = true`:

- A finished oneshot is **inactive**, so its start job is never considered redundant (`job.c:446-448`).
- `initrd-cleanup.service` runs `systemctl --no-block isolate initrd-switch-root.target`.
- That target wants `initrd-root-fs.target` → requires `sysroot.mount` → (via our `requiredBy`)
  requires `rollback.service`.
- Dependencies are pulled in even for already-active units (`transaction.c:1035` tests only `is_new`).
  `transaction_drop_redundant` drops the redundant *mount* job but keeps its dependencies.
- `transaction_collect_garbage`, which would reap the now-orphaned rollback job, **is skipped in
  `JOB_ISOLATE` mode** (`transaction.c:749,774`).
- → the rollback fires again, this time **after `/sysroot` is mounted**.

Poettering described exactly this and prescribed `RemainAfterExit=yes` in systemd#29367 (2023-09-29).
Every in-tree initrd oneshot that gates a mount sets it: `zfs.nix:180-183`, `bcachefs.nix`, `initrd.nix:706-709`.

**Why this explains both May failures, and the old theory does not:**

| | gen 126 (move-aside) | gen 127 (delete-recreate) |
|---|---|---|
| observed | booted, but `/` was a **fresh blank snapshot** parked at `old_roots/@root_<ts>` | hard hang, NumLock dead, no journal |
| re-run explains it | run 1 moves `@root` aside + snapshots fresh; mount takes the fresh one; **run 2 moves the live mounted root into `old_roots/`** ✅ exact match | run 2 deletes the live root mid-switch-root ✅ |
| ordering race explains it | ✗ a lost race would leave `/` on the **previous boot's unwiped** root, not a fresh snapshot | — |

Two further theories floated on 2026-09-24 and **refuted**:
- *"`before = [ "sysroot.mount" ]` is unreliable."* Unsupported. By this file's own chronology, attempt 1 —
  the one that produced the parked-root evidence — had **no `before` at all**; it was added only in attempt 2.
  `before` + `requiredBy` + `DefaultDependencies=false` is the exact triple nixpkgs uses in `zfs.nix`,
  `bcachefs.nix` and `overlayfs.nix`.
- *"The hang was a failed unit dropping into a `*`-locked sulogin."* Does not fit: sulogin prints
  "Cannot open access to console, the root account is locked" and waits on Enter, and the kernel keeps
  driving the NumLock LED. NumLock was dead, so gen 127 was a genuine freeze.

---

## Is there an official recommended way? No.

Checked 2026-09-24 across the release notes, the manual, the option docs, GitHub and the community:

- **Official guidance is one assertion string**, `initrd.nix:502-521`: use `boot.initrd.systemd.services`,
  "refer to `bootup(7)` … and order services accordingly". No worked example anywhere.
- The **26.05 release notes** list four undetectable pitfalls (LUKS `/dev/mapper` naming,
  `cryptsetup-askpass`, kernel params, `/dev/root`) and **never mention `postDeviceCommands`**.
  None of the four applies to Diana.
- The **manual has no systemd-initrd chapter**, and the tree has **no built-in option** for an ephemeral
  or rolled-back root.
- **nix-community/impermanence is stale** — its README still shows *scripted* hooks. The nearest
  authoritative snippet is ElvishJerricco's own PR #321, open and unreviewed since 2026-04-20.
- **Misterio77** (now `Misterio77/Foundry`, `hosts/nixos/common/optional/ephemeral-btrfs.nix`) uses
  `wantedBy = [ "initrd.target" ]` with **no `requiredBy`**, no `path`, `delete -R` then snapshot.
  That dodges the re-run bug by never entering the isolate transaction — but it is **fail-open**:
  a failed rollback boots a stale root silently. We deliberately choose fail-closed instead.

---

## System facts (verified 2026-09-24 — the old list had three stale entries)

- **One btrfs filesystem**, UUID `3e5658eb-f316-490b-855c-9efce6e920eb`.
  Device node **varies across boots** (`nvme2n1p2` ↔ `nvme0n1p2`) — **always by-uuid**.
  ⚠ The current scripted wipe still hard-codes `/dev/nvme2n1p2`. The migration fixes that.
- **Subvolumes:** `@root` → `/` (wiped), `@root-blank` (template, UUID `714582d8-…`), `@home` → `/home`
  (`neededForBoot`), `@persist` → `/persist` (`neededForBoot`), `@nix`, `@log`, plus `old_roots/`.
- `@root`'s nested subvolumes are just `/srv` and `/var/tmp` → deleting it is ~3 cheap btrfs ops.
- **No LUKS, no hibernation.** ~~no swap~~ **CORRECTED: there IS swap** — `modules/system/swap.nix` gives
  zram (priority 100) plus a **32 GiB `/persist/swapfile`** (priority 10), and earlyoom.
- ~~Kernel pinned to 7.0.5~~ **CORRECTED: unpinned since 2026-06-08**, now `pkgs.linuxPackages_latest`.
- ~~26.05~~ **CORRECTED: running 26.11.20260923 (Zokor)**, nixpkgs `8825bebf6324`.
- ~~This file is untracked~~ **CORRECTED: it is tracked in git.**
- **Hosts:** `diana` (real) and `lenovo` (scaffold — `hardware.nix` is commented-out `REPLACE-ME`, cannot
  evaluate a root filesystem; pre-existing and unrelated).

### Verified nixpkgs facts (don't re-derive)

- Non-empty `postDeviceCommands` + `boot.initrd.systemd.enable = true` **fails evaluation**
  (`initrd.nix:502-521`). `boot.nix` is shared, so **both** hosts' `impermanence.nix` must migrate in the
  **same commit**.
- `sysroot.mount` is **not** a NixOS unit. `boot.initrd.systemd.units` holds only `sysroot-run.mount` and
  `sysroot-var-lib-nixos.mount`; the root mount is emitted at runtime by **systemd-fstab-generator** from
  `SYSTEMD_SYSROOT_FSTAB` (`tasks/filesystems.nix:322-327,525-527`). It carries `DefaultDependencies=no`
  and is gated only on the device unit, so it fires as soon as udev sees the disk — before `basic.target`.
- **`path` REPLACES PATH in stage 1.** `stage1ServiceConfig` omits the stage-2 defaults
  (`systemd-lib.nix:648-650,710`). Setting `path = [ pkgs.btrfs-progs ]` would hide `/bin`'s coreutils and
  break `mkdir`/`date` under the injected `set -e`. **Omit `path`** — `/bin` already has coreutils,
  btrfs-progs (`btrfs.nix:118`), bash, and mount/umount via `extraBin`.
- `btrfs subvolume delete -R` exists in btrfs-progs 7.1. Never hand-roll `subvolume list -o` recursion.
- `requiredBy` is realised as a `.requires` symlink, so it does **not** appear in the unit's `[Unit]` text.
- `boot.initrd.systemd.emergencyAccess` defaults to `false`, which writes `root:*` into the initrd's
  `/etc/shadow` (`initrd.nix:331-348,578-586`).

---

## The change (all in ONE commit)

**`modules/system/boot.nix`**
```nix
  boot.initrd.systemd.enable = true;
  boot.initrd.systemd.emergencyAccess = true;   # TEMPORARY: revert once proven
```

**`hosts/diana/impermanence.nix`** — header becomes `{ config, lib, pkgs, utils, ... }:`, and the
`postDeviceCommands` block is replaced by:

```nix
let
  rootDeviceUnit = "${utils.escapeSystemdPath config.fileSystems."/".device}.device";
in {
  boot.initrd.systemd.services.rollback = {
    description = "Rollback btrfs @root to a pristine @root-blank snapshot";
    wantedBy   = [ "initrd.target" ];    # Before= alone never pulls a unit into the transaction
    after      = [ rootDeviceUnit ];
    requires   = [ rootDeviceUnit ];
    before     = [ "sysroot.mount" "shutdown.target" ];
    requiredBy = [ "sysroot.mount" ];    # fail-closed: a failed rollback must not mount a stale root
    conflicts  = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;            # ← THE FIX. Without it the isolate re-runs it after /sysroot mounts.
      TimeoutStartSec = "180s";          # a stall fails to emergency instead of hanging forever
    };
    # NO `path` — see the verified-facts note above.
    script = ''
      set -euo pipefail
      # Guard: never touch a root that is already mounted. Makes a stray second
      # invocation a no-op instead of the disaster gen 127 was.
      while read -r _ mp _; do [ "$mp" = /sysroot ] && exit 0; done < /proc/self/mounts
      mkdir -p /mnt
      mount -t btrfs -o subvol=/ /dev/disk/by-uuid/3e5658eb-f316-490b-855c-9efce6e920eb /mnt
      if [ -e /mnt/@root ]; then btrfs subvolume delete -R /mnt/@root; fi
      # Always snapshot, unconditionally: a crash between delete and snapshot must not
      # leave every future boot failing closed on a missing @root.
      btrfs subvolume snapshot /mnt/@root-blank /mnt/@root
      umount /mnt
    '';
  };
}
```

**`hosts/lenovo/impermanence.nix`** — same replacement, keeping its `REPLACE-ME` device. It only has to
evaluate, not boot.

---

## Execution: two reboots, gated

### Phase 0 — preflight (no reboot)
1. `sudo bash ~/cleanup-old-roots.sh` → `--apply` if it lists anything.
2. Safety snapshots:
   ```
   sudo mount -o subvolid=5 /dev/disk/by-uuid/3e5658eb-f316-490b-855c-9efce6e920eb /tmp/tl
   sudo btrfs subvolume snapshot -r /tmp/tl/@home    /tmp/tl/@home-backup
   sudo btrfs subvolume snapshot -r /tmp/tl/@persist /tmp/tl/@persist-backup
   sudo umount /tmp/tl
   ```
3. `findmnt -no SOURCE /` → must be `[/@root]`, not `old_roots/*`.
4. `sudo btrfs subvolume get-default /` → **must not be `@root`**. The kernel refuses to delete the
   default subvolume, which would make the rollback fail closed on every boot.
5. A scripted fallback generation must be reachable in the boot menu. (As of 2026-09-24 **every**
   generation is scripted, so this is already satisfied.)

### Phase 1 — prove the ordering, wipe nothing
Deploy the unit above **with the probe script instead of the wipe** — same ordering, same dependencies,
deletes nothing:
```sh
      set -euo pipefail
      already=no
      while read -r _ mp _; do [ "$mp" = /sysroot ] && already=yes; done < /proc/self/mounts
      mkdir -p /mnt
      mount -t btrfs -o subvol=/ /dev/disk/by-uuid/3e5658eb-f316-490b-855c-9efce6e920eb /mnt
      { echo "=== $(date -Is 2>/dev/null || echo no-date) invocation"
        if [ "$already" = yes ]; then echo "FAIL - /sysroot ALREADY MOUNTED"; else echo "OK - ordering holds"; fi
      } >> /mnt/ordering-probe.txt
      sync
      umount /mnt
```
One block is appended **per invocation** — so the re-run bug, if it survived, shows up as *two* blocks
from one boot rather than being assumed away.

```
nix flake check      # lenovo still fails on its pre-existing REPLACE-ME root fs
sudo nixos-rebuild boot --flake ~/nix-config#diana      # boot, NEVER switch, on initrd changes
reboot
```
Then read it:
```
sudo mount -o subvolid=5 /dev/disk/by-uuid/3e5658eb-f316-490b-855c-9efce6e920eb /tmp/tl
cat /tmp/tl/ordering-probe.txt ; sudo umount /tmp/tl
```
**Gate — all of:** exactly **one** block for that boot, saying `OK`; `journalctl -b -u rollback.service`
shows exactly **one** start; `systemctl --failed` clean.

Optional live inspection, no rebuild needed — type at the boot menu (the systemd-boot editor is enabled):
`rd.systemd.break=pre-mount` drops a shell exactly where the rollback runs, where `systemctl cat sysroot.mount`
and `systemctl list-dependencies --before rollback.service` settle ordering directly.
`systemd.mask=rollback.service` disables the unit for one boot.

### Phase 2 — enable the real wipe
Swap the probe script for the wipe script (ordering stanzas byte-identical). `sudo touch /WIPE-TEST`,
`nixos-rebuild boot`, reboot.

**Gate — all four:** `/WIPE-TEST` gone · `findmnt -no SOURCE /` is `[/@root]` and **not** `old_roots/*` ·
`journalctl -b | grep -i rollback` clean, one start · `/home`, `/persist`, `~/.ssh`, `~/nix-config` intact.

### Phase 3 — cleanup
Revert `emergencyAccess`, delete this file, retire `~/cleanup-old-roots.sh` (`old_roots/` stops growing
once delete-and-recreate is live), and record the outcome in memory.

---

## If it goes wrong

Select the previous generation in the systemd-boot menu — the proven recovery from May. Then
`boot.initrd.systemd.enable = false`, `nixos-rebuild boot`, reboot. `@home`, `@persist`, `@nix` and `@log`
are separate subvolumes the rollback never touches, and Phase 0 leaves read-only snapshots of the two
that matter.

**Residual risks, stated honestly:** the re-run mechanism was established by reading systemd v261.2
source, not by reproducing it (the May journals are gone — retention starts 2026-08-29). Fail-closed means
any rollback error lands in emergency, which is why `emergencyAccess = true` goes in for the test boots.
`configurationLimit = 10` rotates scripted fallbacks out after ten rebuilds, so don't dawdle across many
unrelated rebuilds. And this unit has no upstream owner: a future systemd or nixpkgs ordering change will
not be caught for you.

---

## Handy commands

- Which generation: `readlink -f /run/booted-system` · list: `ls -1dt /nix/var/nix/profiles/system-*-link`
- Delete bad generations: `sudo nix-env -p /nix/var/nix/profiles/system --delete-generations <N…> && sudo /run/current-system/bin/switch-to-configuration boot`
- Escaped device unit name: `systemd-escape -p --suffix=device /dev/disk/by-uuid/3e5658eb-f316-490b-855c-9efce6e920eb`
- Render the unit without applying: `nix eval --raw '.#nixosConfigurations.diana.config.boot.initrd.systemd.units."rollback.service".text'`
