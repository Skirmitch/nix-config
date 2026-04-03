{ ... }: {
  imports = [ ./aagl.nix ];

  # --- GAMING ---
  programs.steam.enable = true;
  hardware.xpadneo.enable = true;
  boot.extraModprobeConfig = ''
  options bluetooth disable_ertm=1
  options xpadneo disable_deadzones=0
  '';
}
