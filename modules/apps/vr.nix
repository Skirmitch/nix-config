{ pkgs, lib, modulesPath, ... }:
let
  # SteamVR's compositor launcher — lives in the user's Steam library, so it
  # is rewritten on every SteamVR update.
  steamvrLauncher =
    "/home/skirmitch/.local/share/Steam/steamapps/common/SteamVR/bin/linux64/vrcompositor-launcher";

  # Tripwire for the avahi warning fix at the bottom of this file. `pathExists`
  # guards an upstream rename: a bare `readFile` of a vanished path throws and
  # takes the WHOLE eval down, which is a worse failure than the warning we are
  # silencing. The infix is the obsolete option wivrn.nix still sets; one
  # occurrence in nixpkgs 02c087f3fe.
  wivrnModule = "${modulesPath}/services/video/wivrn.nix";
  wivrnStillSetsObsoleteAvahiOptions =
    builtins.pathExists wivrnModule
    && lib.hasInfix "userServices = true;" (builtins.readFile wivrnModule);
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
  #
  # sidequest was dropped 2026-10-05. nixpkgs still packages 0.10.42, whose
  # upstream release is 2024-05-02 (upstream itself is at 1.3.1), and the
  # 2026-10-03 nixpkgs marked it insecure for EOL Electron 29 - which refuses
  # evaluation of the WHOLE system, not just that package. Sideloading rides
  # on android-tools below (`adb install`). If it is ever wanted back, take
  # upstream's own AppImage; do not allow nixpkgs' 2024 build.
  environment.systemPackages = with pkgs; [
    android-tools    # adb + fastboot
    openxr-loader    # system OpenXR loader
    xrizer           # OpenVR -> OpenXR translator for WiVRn (maintained)
    opencomposite    # older OpenVR -> OpenXR translator, kept as fallback
  ];

  # adb for the Galaxy Z Fold 7 (vendor 04e8, hc-sync sideloads) rides on
  # android-tools above plus systemd 258's generic uaccess rule; nixpkgs
  # removed programs.adb for exactly that reason (checked 2026-09-08).

  # Explicit USB access for Meta/Oculus devices (vendor ID 2833 = Quest 3).
  # systemd 258's generic uaccess rule matches by interface class, so this is
  # belt-and-suspenders for adb device access.
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

  # --- Silence the two avahi "obsolete option" warnings that services.wivrn
  #     above drags in (4 of the 8 warning lines every `dif` printed) ---
  #
  # nixpkgs' own module, nixos/modules/services/video/wivrn.nix, sets
  # `services.avahi.publish.{enable,userServices} = true`. Both were made
  # obsolete in the avahi module, so every eval of this system printed an
  # obsolescence notice for options we never wrote. Checked against nixpkgs
  # master on 2026-10-23: still unfixed upstream, so it has to be absorbed here.
  #
  # The mechanism (avahi-daemon.nix:475-483): the warning fires on
  # `cfg.publish.<x> != null`, so forcing them back to null removes it. mkForce
  # is required - wivrn.nix sets them as plain definitions, not mkDefault. The
  # same `!= null` guards the mkIf blocks that translated those options into
  # `settings.publish.*` (:489-497), so we write those three settings ourselves:
  # exactly the values the warning text prescribes, and exactly what the old
  # options resolved to for enable = userServices = true. mkDefault keeps a
  # future upstream fix from colliding with us.
  #
  # VERIFIED 2026-10-23, not reasoned: `services.avahi.settings` is identical
  # before and after, avahi-daemon.conf stays the same store path
  # (bky2j5pqycyk7rzpk6bfxvmwcy03mnx0-avahi-daemon.conf), and
  # system.build.toplevel.drvPath is unchanged. Zero rebuild, zero behaviour
  # change - mDNS publishing and user services stay on, which WiVRn needs to
  # advertise itself to the headset.
  services.avahi.publish = {
    enable = lib.mkForce null;
    userServices = lib.mkForce null;
  };
  services.avahi.settings.publish = {
    disable-publishing = lib.mkDefault false;
    disable-user-service-publishing = lib.mkDefault false;
    publish-addresses = lib.mkDefault true;
  };

  # Silent today; one actionable line the day upstream fixes wivrn.nix, so the
  # workaround above gets deleted instead of quietly rotting into a no-op.
  warnings = lib.optional (!wivrnStillSetsObsoleteAvahiOptions) ''
    modules/apps/vr.nix: nixpkgs' wivrn module no longer sets the obsolete
    services.avahi.publish options. The mkForce/settings.publish block in that
    file is now dead weight - delete it and this warning.
  '';
}
