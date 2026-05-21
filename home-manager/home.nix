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
