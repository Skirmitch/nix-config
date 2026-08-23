{ pkgs, ... }: {
  home.packages = with pkgs; [
    jq
    opencode
    (pkgs.symlinkJoin {
    name = "discord";
    paths = [ pkgs.discord ];
    buildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/discord \
        --unset NIXOS_OZONE_WL
    '';
  })
    vivaldi
    gedit
    btop
    nano
    pciutils
    dmidecode
    gnomeExtensions.kimpanel
    nvitop
    libreoffice
    obsidian
    drawing
    # Zoom's FHS sandbox can't see the host's xdg-desktop-portal, and on
    # Wayland screen capture only works through the portal. nixpkgs defaults
    # gnomeXdgDesktopPortalSupport to false, so share-screen silently fails.
    (zoom-us.override { gnomeXdgDesktopPortalSupport = true; })
  ];

  xdg.desktopEntries.discord = {
    name = "Discord";
    exec = "discord";
    icon = "discord";
    genericName = "All-in-one cross-platform voice and text chat for gamers";
    categories = [ "Network" "InstantMessaging" ];
    mimeType = [ "x-scheme-handler/discord" ];
  };
}
