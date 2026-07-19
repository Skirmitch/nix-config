{ lib, pkgs, ... }:
let
  # Upstream libgphoto2 (incl. master as of 2026-07) segfaults on
  # `--set-config liveviewsize`: ptp_panasonic_9415 passes a stack array
  # cast to unsigned char**, so the payload bytes get dereferenced as a
  # pointer. Without the fix the G9 is stuck at 640x480 live view.
  libgphoto2-fixed = pkgs.libgphoto2.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./g9cam-libgphoto2-liveviewsize-segv.patch ];
  });
  gphoto2-fixed = pkgs.gphoto2.override { libgphoto2 = libgphoto2-fixed; };

  # Lumix G9 (mounted on the Leica S9D microscope) -> virtual webcam.
  # Camera must be on USB, awake, USB Mode = PC(Tether), dial on M.
  g9cam = pkgs.writeShellScriptBin "g9cam" ''
    set -uo pipefail
    DEV=''${G9CAM_DEV:-/dev/video9}

    # GNOME's gvfs monitor grabs the PTP session intermittently
    # ("PTP Device Busy"); it respawns on demand after we exit.
    ${pkgs.procps}/bin/pkill -f gvfs-gphoto2-volume-monitor 2>/dev/null || true

    ${gphoto2-fixed}/bin/gphoto2 --set-config liveviewsize='1280x960 700 30HZ' \
      || echo "g9cam: could not set live view size (camera asleep?), continuing" >&2

    echo "g9cam: streaming G9 live view to $DEV — Ctrl-C to stop" >&2
    ${gphoto2-fixed}/bin/gphoto2 --stdout --capture-movie \
      | ${pkgs.ffmpeg}/bin/ffmpeg -hide_banner -loglevel warning \
          -f mjpeg -i - -vf format=yuv420p -f v4l2 "$DEV"
  '';
in
{
  environment.systemPackages = [ gphoto2-fixed g9cam ];

  # immersed.nix already loads v4l2loopback with a single unnumbered device.
  # Re-declare the full parameter set AFTER its options line (the kernel
  # keeps the last assignment per parameter): video0 stays Immersed's,
  # video9 is the G9's. Takes effect on module (re)load, i.e. after reboot
  # or `rmmod v4l2loopback && modprobe v4l2loopback`.
  boot.extraModprobeConfig = lib.mkAfter ''
    options v4l2loopback devices=2 video_nr=0,9 exclusive_caps=1,1 card_label="v4l2loopback Virtual Camera,Lumix G9 (Leica S9D)"
  '';
}
