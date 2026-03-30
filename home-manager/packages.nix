{ pkgs, ... }: {
  home.packages = with pkgs; [
    jq
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
    git
    gedit
    btop
    nano
    pciutils
    dmidecode
    gnomeExtensions.kimpanel
    nvitop
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
