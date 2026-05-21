{ pkgs, ... }: {
  # --- Immersed — VR multi-monitor desktop agent (Meta Quest 3) ---
  # PC-side agent only; the headset app installs from the Meta Store.
  # programs.immersed installs the immersed-vr package and loads the
  # v4l2loopback (out-of-tree) + snd-aloop kernel modules for Immersed's
  # virtual camera and audio routing.
  programs.immersed.enable = true;

  # Immersed needs VA-API for video. extraPackages is a list, so this
  # merges with the hardware.graphics block in graphics.nix.
  hardware.graphics.extraPackages = with pkgs; [ libva libva-vdpau-driver ];
}
