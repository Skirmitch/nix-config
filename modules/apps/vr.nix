{ pkgs, ... }: {
  # --- VR / PCVR streaming (Meta Quest 3) ---

  # ALVR — streams through SteamVR (registers itself as a SteamVR driver).
  programs.alvr = {
    enable = true;
    openFirewall = true;            # TCP + UDP 9943-9944
  };

  # WiVRn — Monado-based streaming; self-manages its own OpenXR runtime.
  services.wivrn = {
    enable = true;
    package = pkgs.wivrn.override { cudaSupport = true; }; # NVENC (NVIDIA) encoding
    openFirewall = true;            # TCP + UDP 9757
    highPriority = true;            # cap_sys_nice wrapper for steadier frame pacing
    steam.importOXRRuntimes = true; # expose the OpenXR runtime to Steam's sandbox
  };

  # Sideloading and OpenXR tooling.
  environment.systemPackages = with pkgs; [
    sidequest        # Quest sideloading / file management
    android-tools    # adb + fastboot
    openxr-loader    # system OpenXR loader
    xrizer           # OpenVR -> OpenXR translator for WiVRn (maintained)
    opencomposite    # older OpenVR -> OpenXR translator, kept as fallback
  ];

  # Explicit USB access for Meta/Oculus devices (vendor ID 2833 = Quest 3).
  # systemd 258's generic uaccess rule matches by interface class, so this is
  # belt-and-suspenders for adb / SideQuest device access.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTR{idVendor}=="2833", MODE="0660", TAG+="uaccess"
  '';

  # Second login session (X11 + Xfce) dedicated to ALVR + SteamVR. GNOME/Wayland
  # stays the default and is untouched — this only adds an extra pick at the
  # login screen, for games needing SteamVR's reference-grade compatibility.
  services.xserver.enable = true;
  services.xserver.desktopManager.xfce.enable = true;
}
