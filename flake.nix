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
    # Tracks upstream main. Upstream's addTrustedFolder .asar-guard patch can't find
    # its anchor in Claude Desktop 1.9659.2+, which would abort the build; modules/apps/
    # claude.nix patches the upstream source to make just that one (non-load-bearing)
    # patch skip instead of exit 1. That override self-deactivates once upstream fixes
    # the regex, so no re-pin is needed (cf. the 2026-05-20 tray-menu break).
    # Pinned 2026-06-12: HEAD (d2ce046, app 1.12603.1) fatally fails its own
    # --add-dir .asar filter patch (#649) — anchor matches twice in the new app.
    # Un-pin once upstream adapts the patch script.
    claude-desktop.url = "github:aaddrick/claude-desktop-debian/e85450c90ba38159f89f02bdd0f6c6d7e6bce065";
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
