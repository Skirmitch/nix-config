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
}
