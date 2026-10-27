{ pkgs, ... }: {
  # --- BOOT (host-agnostic) ---
  # Host-specific kernel pins / EC modules live under hosts/<name>/.
  boot.loader.systemd-boot = { enable = true; configurationLimit = 10; };
  boot.loader.efi.canTouchEfiVariables = true;
  # No `boot.initrd.systemd.enable`: nixpkgs removed scripted initrd in the
  # 2026-10-26 bump and the option is now mkRemovedOptionModule, so even
  # setting it to `true` refuses eval. systemd stage 1 is the only initrd.
}
