{ pkgs, ... }: {
  # --- Sunshine: desktop / game streaming host for Moonlight ---
  # LAN-only GameStream host, paired with the Moonlight client on the
  # Quest 3. The services.sunshine module runs it as a systemd *user*
  # service (auto-starting on graphical login), opens the firewall ports,
  # loads the uinput kernel module, and installs the udev rules that let
  # Sunshine inject keyboard / mouse / gamepad input without root.

  services.sunshine = {
    enable = true;
    autoStart = true;
    openFirewall = true;   # Sunshine stream + web-UI ports (47984-48010 range)
    capSysAdmin = true;    # CAP_SYS_ADMIN: needed for KMS screen capture on Wayland

    # RTX 3060 Ti NVENC. The plain sunshine build ships without CUDA, so the
    # NVIDIA encoder fails to load ("Cannot load libnvidia-encode.so.1") and
    # Sunshine drops to software x264. cudaSupport links the hardware path.
    package = pkgs.sunshine.override { cudaSupport = true; };
  };
}
