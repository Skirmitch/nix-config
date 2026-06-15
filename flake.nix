{
  description = "Skirmitch's NixOS Flake Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    impermanence.url = "github:nix-community/impermanence";

    home-manager = {
      # Un-pinned 2026-06-05 back to master: nixpkgs nixos-unstable rolled over to
      # 26.11, so the temporary release-26.05 pin (2026-05-30) became the stale side
      # and tripped the mismatch warning. HM has no release-26.11 branch yet; master
      # tracks unstable and reports 26.11 (release.json), matching nixpkgs.
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Un-pinned 2026-06-05 back to main alongside home-manager: nixpkgs reached 26.11,
    # so the temporary release-26.05 pin (2026-06-01) now mismatches. aagl has no
    # release-26.11 branch; main declares aaglReleaseBranch = "26.11", matching nixpkgs.
    aagl.url = "github:ezKEa/aagl-gtk-on-nix";
    aagl.inputs.nixpkgs.follows = "nixpkgs";
    # Tracks upstream main (unpinned). Upstream's reverse-engineered patches can
    # abort the whole rebuild when a new minified Claude Desktop bundle breaks a
    # patch's anchor/assertion. modules/apps/claude.nix builds from a patched copy
    # of this source that makes those two known failure modes non-fatal (the
    # non-load-bearing addTrustedFolder guard, and the #649 --add-dir filter's
    # >1-match bail), so version bumps flow without blocking the rebuild. Both
    # fixes self-deactivate once upstream adapts, so no re-pin is needed.
    # Un-pinned 2026-06-15 (was pinned 2026-06-12 to e85450c for the #649
    # double-match break, now absorbed by the override).
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
        # Make readable substitutions first, then hard-filter to the charset
        # system.nixos.label allows ([a-zA-Z0-9:_.-]) so stray chars like '+'
        # can't break the build.
        mapped = builtins.replaceStrings ["\n" " " "/"] ["" "_" "-"] raw;
        chars = nixpkgs.lib.stringToCharacters mapped;
        clean = builtins.concatStringsSep ""
          (builtins.filter (c: builtins.match "[a-zA-Z0-9:_.-]" c != null) chars);
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
