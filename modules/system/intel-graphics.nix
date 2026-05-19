{ pkgs, ... }: {
  # --- Intel iGPU (host-imported) ---
  # For Lenovo / Intel-only laptops. If your laptop has a hybrid NVIDIA GPU,
  # also import ./nvidia.nix and configure PRIME offload.
  services.xserver.videoDrivers = [ "modesetting" ];

  hardware.graphics.extraPackages = with pkgs; [
    intel-media-driver
    vpl-gpu-rt
  ];
}
