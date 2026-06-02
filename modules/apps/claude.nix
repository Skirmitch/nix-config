{ inputs, pkgs, ... }:
let
  # Upstream's addTrustedFolder .asar-guard patch (scripts/patches/config.sh) can't
  # locate its anchor in Claude Desktop 1.9659.2+, aborting the whole build with a
  # fatal "[FAIL] addTrustedFolder anchor not found". That patch is only a hardening
  # guard against .asar paths in LocalAgentMode/cowork trusted folders — it is NOT
  # load-bearing for launching or normal use. So we build from a patched copy of the
  # upstream source where that one failure path skips (exit 0) instead of aborting
  # (exit 1); the guard simply isn't injected.
  #
  # The sed targets only the line *after* the addTrustedFolder FAIL message, so it
  # leaves the config-write patch's identical exit(1) untouched. It is also
  # self-deactivating: once upstream fixes the anchor and that patch succeeds, the
  # neutered exit path is never reached (harmless), and if upstream removes the line
  # the sed becomes a no-op — so this override needs no manual cleanup on the un-fix.
  claudeDesktopSrc = pkgs.applyPatches {
    name = "claude-desktop-debian-asar-guard-nonfatal";
    src = inputs.claude-desktop;
    postPatch = ''
      sed -i '/\[FAIL\] addTrustedFolder anchor not found/{n;s/process\.exit(1)/process.exit(0)/}' \
        scripts/patches/config.sh
    '';
  };
in
{
  nixpkgs.overlays = [
    inputs.claude-desktop.overlays.default
    # Rebuild claude-desktop from the patched source above, overriding the
    # unpatched package the upstream overlay defines.
    (final: _prev: {
      claude-desktop = final.callPackage "${claudeDesktopSrc}/nix/claude-desktop.nix" {
        node-pty = final.callPackage "${claudeDesktopSrc}/nix/node-pty.nix" { };
      };
    })
  ];
  environment.systemPackages = [
    pkgs.claude-desktop
    inputs.claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
