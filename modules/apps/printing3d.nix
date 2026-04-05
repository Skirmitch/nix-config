{ pkgs, ... }: {
  # --- 3D PRINTING ---
  environment.systemPackages = with pkgs; [
    cura
  ];

  # Allow serial access to the printer (USB)
  services.udev.extraRules = ''
    SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666", SYMLINK+="creality"
  '';
}
