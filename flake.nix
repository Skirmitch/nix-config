{
  description = "Skirmitch's NixOS Flake Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    impermanence.url = "github:nix-community/impermanence";

    home-manager = {
      # Pinned 2026-05-30 to release-26.05 to match nixpkgs nixos-unstable (26.05).
      # HM master jumped to 26.11 at the release boundary, tripping the version-mismatch
      # warning. Bump to release-26.11 (or back to master) once nixpkgs reaches 26.11.
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Pinned 2026-06-01 to release-26.05 to match nixpkgs (26.05). aagl's main
    # branch jumped to release 26.11 at the boundary, tripping its built-in
    # nixpkgs-release mismatch warning. Bump to release-26.11 once nixpkgs reaches
    # 26.11 (same story as the home-manager pin above).
    aagl.url = "github:ezKEa/aagl-gtk-on-nix/release-26.05";
    aagl.inputs.nixpkgs.follows = "nixpkgs";
    # Tracks upstream main. Upstream's addTrustedFolder .asar-guard patch can't find
    # its anchor in Claude Desktop 1.9659.2+, which would abort the build; modules/apps/
    # claude.nix patches the upstream source to make just that one (non-load-bearing)
    # patch skip instead of exit 1. That override self-deactivates once upstream fixes
    # the regex, so no re-pin is needed (cf. the 2026-05-20 tray-menu break).
    claude-desktop.url = "github:aaddrick/claude-desktop-debian";
    claude-code-nix.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, home-manager, impermanence, aagl, ... }@inputs:
    let
      nixosLabel = let
        labelPath = ./.nixos-label;
        raw = if builtins.pathExists labelPath
          then builtins.readFile labelPath
          else "default";
        clean = builtins.replaceStrings ["\n" " " ":" "/"] ["" "_" "-" "-"] raw;
      in builtins.substring 0 50 clean;

      mkHost = hostName: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs nixosLabel; };
        modules = [
          ./hosts/${hostName}
          impermanence.nixosModules.impermanence
          home-manager.nixosModules.home-manager
          aagl.nixosModules.default
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.skirmitch = import ./home-manager/home.nix;
          }
        ];
      };
    in {
      nixosConfigurations = {
        diana = mkHost "diana";
        lenovo = mkHost "lenovo";
      };
    };
}
