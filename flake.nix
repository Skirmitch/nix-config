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
    # PINNED 2026-06-17 to the last version that actually LAUNCHES (1.12603.1).
    # Upstream's reverse-engineered patches can break against a new minified
    # bundle. modules/apps/claude.nix's build-time seds absorb the two known
    # *build* failure modes (addTrustedFolder anchor, #649 --add-dir >1-match),
    # but the 1.13576.0 bump (rev da341d, 2026-06-17) introduced a *runtime*
    # break the build can't catch: the app builds fine, then hangs before
    # app-ready and never opens a window (verified GPU on/off; our seds are
    # no-ops against that rev, so it's upstream, not us). Pinning to 2d1d0c5
    # (1.12603.1, 2026-06-15) — the previous, working version.
    # UNPIN TEST when bumping the flake: override this input to HEAD, rebuild,
    # then `CLAUDE_DISABLE_GPU=0 timeout 30 claude-desktop` and confirm
    # ~/.config/Claude/logs/main.log gains a fresh "app-ready" line. If it does,
    # drop the rev suffix below (back to bare ".../claude-desktop-debian") and
    # re-pin only if a future bump regresses again. See claude.nix for the seds.
    # History: un-pinned 2026-06-15; before that pinned 2026-06-12 to e85450c.
    claude-desktop.url = "github:aaddrick/claude-desktop-debian/2d1d0c59ffb94c0de8a0c5627d03c28099599792";
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
