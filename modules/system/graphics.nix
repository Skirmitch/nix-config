{ config, pkgs, ... }: {
  # --- GRAPHICS / DESKTOP (host-agnostic) ---
  # Vendor-specific bits (NVIDIA, etc.) live in sibling modules and are
  # imported per-host.
  services.xserver.enable = true;

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  environment.sessionVariables = {
    CLAUDE_USE_WAYLAND = "1";
  };

  hardware.graphics = { enable = true; enable32Bit = true; };
}
