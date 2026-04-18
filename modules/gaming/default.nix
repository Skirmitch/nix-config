{ pkgs, ... }: {
  imports = [ ./aagl.nix ];

  # --- GAMING ---
  programs.steam.enable = true;
  hardware.xpadneo.enable = true;
  boot.extraModprobeConfig = ''
  options bluetooth disable_ertm=1
  options xpadneo disable_deadzones=0
  '';


  # Fix for systemd 258 breaking xpadneo input (NixOS unstable bug)
  services.udev.packages = [
    (pkgs.writeTextFile {
      name = "60-xpadneo";
      text = ''
        ACTION=="bind", SUBSYSTEM=="hid", DRIVER!="xpadneo", KERNEL=="0005:045E:*", KERNEL=="*:02FD.*|*:02E0.*|*:0B05.*|*:0B13.*|*:0B20.*|*:0B22.*", ATTR{driver/unbind}="%k", ATTR{[drivers/hid:xpadneo]bind}="%k"
        ACTION!="remove", DRIVERS=="xpadneo", SUBSYSTEM=="input", TAG+="uaccess"
      '';
      destination = "/etc/udev/rules.d/60-xpadneo.rules";
    })
    (pkgs.writeTextFile {
      name = "70-xpadneo-disable-hidraw";
      text = ''
        ACTION!="remove", DRIVERS=="xpadneo", SUBSYSTEM=="hidraw", MODE:="0000", TAG-="uaccess"
      '';
      destination = "/etc/udev/rules.d/70-xpadneo-disable-hidraw.rules";
    })
  ];

}
