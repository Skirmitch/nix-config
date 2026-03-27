{ config, pkgs, ... }: {
  # --- GRAPHICS (RTX 3060 Ti) ---
  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" ];
    deviceSection = ''Option "Coolbits" "12"''; # For fan control
  };

  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;
  environment.sessionVariables = {
  CLAUDE_USE_WAYLAND = "1";
  NIXOS_OZONE_WL = "1";      # covers other Electron apps like Discord, VS Code
};

  hardware.graphics = { enable = true; enable32Bit = true; };

  hardware.nvidia = {
    powerManagement.enable = true;
    nvidiaSettings = true;
    modesetting.enable = true;
    open = false;
    package = (config.boot.kernelPackages.nvidiaPackages.stable.overrideAttrs {
      src = pkgs.fetchurl {
        url = "https://us.download.nvidia.com/XFree86/Linux-x86_64/595.45.04/NVIDIA-Linux-x86_64-595.45.04.run";
        sha256 = "sha256-zUllSSRsuio7dSkcbBTuxF+dN12d6jEPE0WgGvVOj14=";
      };
    });
  };
}
