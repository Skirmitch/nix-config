{ pkgs, ... }: {
  # --- BOOT (host-agnostic) ---
  # Host-specific kernel pins / EC modules live under hosts/<name>/.
  boot.loader.systemd-boot = { enable = true; configurationLimit = 10; };
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.systemd.enable = false;
}
