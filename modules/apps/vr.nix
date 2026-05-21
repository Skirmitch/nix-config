{ pkgs, ... }:
let
  # SteamVR's compositor launcher — lives in the user's Steam library, so it
  # is rewritten on every SteamVR update.
  steamvrLauncher =
    "/home/skirmitch/.local/share/Steam/steamapps/common/SteamVR/bin/linux64/vrcompositor-launcher";
in
{
  # --- VR / PCVR streaming (Meta Quest 3) ---
  #
  # OpenVR/SteamVR games (e.g. No Man's Sky) stream via Steam Link, which
  # talks to real SteamVR natively. WiVRn (below) handles native-OpenXR
  # titles. ALVR was dropped — Steam Link fully supersedes it.

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

  # Second login session (X11 + Xfce) for SteamVR / Steam Link. SteamVR is
  # unreliable on GNOME/Wayland (the default session), so this adds an extra
  # X11 pick at the login screen. services.xserver itself is enabled in
  # modules/system/graphics.nix.
  services.xserver.desktopManager.xfce.enable = true;

  # SteamVR wants cap_sys_nice on its compositor launcher for steady frame
  # pacing. SteamVR's own setup can't apply it on NixOS (it shells out to a
  # fixed FHS `setcap` path that does not exist here), and every SteamVR
  # update rewrites the binary and wipes the capability. So re-apply it
  # ourselves: once at boot, and again whenever the file changes.
  systemd.services.steamvr-setcap = {
    description = "Grant cap_sys_nice to SteamVR's vrcompositor-launcher";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "steamvr-setcap" ''
        if [ -e "${steamvrLauncher}" ]; then
          ${pkgs.libcap}/bin/setcap cap_sys_nice+ep "${steamvrLauncher}"
        fi
      '';
    };
  };

  # Re-fire the service when SteamVR rewrites the launcher (e.g. after an
  # update). A same-named path unit auto-targets steamvr-setcap.service.
  systemd.paths.steamvr-setcap = {
    description = "Watch SteamVR's vrcompositor-launcher for changes";
    wantedBy = [ "multi-user.target" ];
    pathConfig.PathModified = steamvrLauncher;
  };
}
