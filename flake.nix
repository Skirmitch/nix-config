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

    aagl.url = "github:ezKEa/aagl-gtk-on-nix";
    aagl.inputs.nixpkgs.follows = "nixpkgs";
    # Pinned 2026-05-29: HEAD rev 2ae2172 (Claude Desktop 1.9659.2) fails to build —
    # upstream patch step "[FAIL] addTrustedFolder anchor not found" (.asar guard).
    # Un-pin once upstream fixes the patch regex (cf. the 2026-05-20 tray-menu break).
    claude-desktop.url = "github:aaddrick/claude-desktop-debian/5dd948e96d853ed37636bc0e2368fc2665cd1104";
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
