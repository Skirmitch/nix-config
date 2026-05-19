{ config, pkgs, ... }: {
  # --- NVIDIA proprietary driver (host-imported) ---
  services.xserver = {
    videoDrivers = [ "nvidia" ];
    deviceSection = ''Option "Coolbits" "12"''; # For fan control
  };

  hardware.nvidia = {
    powerManagement.enable = true;
    nvidiaSettings = true;
    modesetting.enable = true;
    open = false;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
}
