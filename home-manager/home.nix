{ pkgs, ... }: {
  imports = [ ./packages.nix ];

  home.username = "skirmitch";
  home.homeDirectory = "/home/skirmitch";
  home.stateVersion = "25.11";

  # Pin the cursor theme declaratively. Logging into Xfce blanks the shared
  # dconf cursor keys (cursor-theme='' / cursor-size=0), which leaves GNOME
  # with the white-square X11 fallback. This re-asserts a real theme on rebuild.
  home.pointerCursor = {
    gtk.enable = true;
    name = "Adwaita";
    package = pkgs.adwaita-icon-theme;
    size = 24;
  };

  # GNOME specific overrides
  dconf.settings = {
    "org/gnome/shell" = {
      enabled-extensions = [ "kimpanel@kde.org" ];
    };
    "org/gnome/desktop/interface" = {
      cursor-theme = "Adwaita";
      cursor-size = 24;
    };
  };

  # The dconf.settings above only re-assert the cursor on rebuild. Since Xfce
  # blanks those keys at runtime, this systemd user service re-asserts them on
  # every GNOME login. It is ordered before gnome-shell so the white-square
  # fallback never even flashes, and it no-ops when the session isn't GNOME
  # (so logging into Xfce won't trigger it).
  systemd.user.services.fix-gnome-cursor = {
    Unit = {
      Description = "Re-assert GNOME cursor theme blanked by Xfce";
      Before = [
        "org.gnome.Shell@x11.service"
        "org.gnome.Shell@wayland.service"
        "gnome-session-initialized.target"
      ];
      After = [ "graphical-session-pre.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = let
        fixCursor = pkgs.writeShellScript "fix-gnome-cursor" ''
          case "$XDG_CURRENT_DESKTOP" in
            *GNOME*) ;;
            *) exit 0 ;;
          esac
          ${pkgs.dconf}/bin/dconf write /org/gnome/desktop/interface/cursor-theme "'Adwaita'"
          ${pkgs.dconf}/bin/dconf write /org/gnome/desktop/interface/cursor-size 24
        '';
      in "${fixCursor}";
    };
    Install = {
      WantedBy = [ "gnome-session-initialized.target" ];
    };
  };

  programs.bash = {
    enable = true;
    initExtra = ''
    rebuild() {
        if [ -z "$1" ]; then
          echo "Usage: rebuild <message>"
          return 1
        fi
        local host=$(hostname | tr '[:upper:]' '[:lower:]')
        cd ~/nix-config && echo "$*" > .nixos-label && git add -A && git commit -m "$*" && sudo nixos-rebuild switch --flake ~/nix-config#"$host"
      }
      dif() {
        local host=$(hostname | tr '[:upper:]' '[:lower:]')
        cd ~/nix-config && nix flake update && nixos-rebuild build --flake ~/nix-config#"$host" && nvd diff /run/current-system ./result
      }
    '';
    shellAliases = {
      update = "cd /home/skirmitch/nix-config && sudo nix flake update /home/skirmitch/nix-config && rebuild \"Updated previous system\"";
      nordconnect = "sudo wgnord connect";
      norddisconnect = "sudo wgnord disconnect";
    };
  };

  programs.home-manager.enable = true;
}
