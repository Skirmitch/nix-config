{ config, pkgs, ... }: {
  # --- GRAPHICS / DESKTOP (host-agnostic) ---
  # Vendor-specific bits (NVIDIA, etc.) live in sibling modules and are
  # imported per-host.
  services.xserver.enable = true;

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Boot into GNOME by default regardless of the last-used session. The VR
  # module's Xfce session stays pickable via GDM's gear icon on the login screen.
  services.displayManager.defaultSession = "gnome";

  environment.sessionVariables = {
    CLAUDE_USE_WAYLAND = "1";
  };

  # Pin GNOME Console as the terminal `xdg-terminal-exec` launches. The VR
  # module's Xfce session also registers xfce4-terminal, which would otherwise
  # make the default pick ambiguous.
  xdg.terminal-exec = {
    enable = true;
    settings.default = [ "org.gnome.Console.desktop" ];
  };

  hardware.graphics = { enable = true; enable32Bit = true; };
}
