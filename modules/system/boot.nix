{ pkgs, ... }: {
  # --- BOOT (host-agnostic) ---
  # Host-specific kernel pins / EC modules live under hosts/<name>/.
  boot.loader.systemd-boot = { enable = true; configurationLimit = 10; };
  boot.loader.efi.canTouchEfiVariables = true;
  # No `boot.initrd.systemd.enable`: nixpkgs removed scripted initrd in the
  # 2026-10-26 bump and the option is now mkRemovedOptionModule, so even
  # setting it to `true` refuses eval. systemd stage 1 is the only initrd.

  # TEMPORARY - REVERT IN PHASE 3 OF THE INITRD MIGRATION.
  #
  # The rollback unit in hosts/diana/impermanence.nix is `requiredBy`
  # sysroot.mount, so a failed rollback stops the boot BY DESIGN. Without this,
  # systemd stage 1 offers no console shell to find out why, and the only
  # recovery is picking an older generation at the boot menu.
  #
  # It is a real loosening: anyone with physical access gets a root shell in the
  # initrd, before any disk encryption prompt or login. That is acceptable for
  # the two migration boots and NOT acceptable as a standing setting, so it
  # comes back out the moment the wipe is verified.
  boot.initrd.systemd.emergencyAccess = true;
}
