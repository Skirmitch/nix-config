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

  # Diana has both an AMD iGPU and the RTX 3060 Ti, and both expose a Vulkan
  # ICD. Vulkan device enumeration order is not stable across reboots, so
  # games and SteamVR sometimes pick the iGPU and render catastrophically
  # slowly (VR on the iGPU is unusable). Pin the Vulkan loader to the NVIDIA
  # ICD so everything always renders on the 3060 Ti.
  environment.sessionVariables.VK_ICD_FILENAMES =
    "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json:/run/opengl-driver-32/share/vulkan/icd.d/nvidia_icd.json";
}
