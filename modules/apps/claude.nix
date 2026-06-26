{ inputs, pkgs, ... }:
let
  # We build claude-desktop from a patched copy of the upstream source so that a
  # new Claude Desktop bundle can't abort the whole NixOS rebuild when one of
  # upstream's reverse-engineered patches fails to match the new minified code.
  # Two independent hardenings, both self-deactivating on healthy versions:
  #
  # 1. addTrustedFolder .asar-guard (config.sh): can't find its anchor in
  #    1.9659.2+, which aborts with "[FAIL] addTrustedFolder anchor not found".
  #    That patch is only a hardening guard against .asar paths in
  #    LocalAgentMode/cowork trusted folders — NOT load-bearing for launching or
  #    normal use — so we make just that failure path skip (exit 0) instead of
  #    aborting (exit 1). The sed targets only the line *after* the addTrustedFolder
  #    FAIL message, leaving the config-write patch's identical exit(1) untouched.
  #
  # 2. #649 --add-dir .asar filter (config.sh sub-patch 1): finds the --add-dir
  #    dispatch loop by regex, then bails (exit 1) if the matched code appears
  #    more than once. App 1.12603.1's minifier duplicated that loop, so it
  #    matches twice -> "FATAL: --add-dir pattern matches 2 times (expected 1)".
  #    This patch IS load-bearing (local agent mode crashes without it), so we
  #    don't skip it — we make it correct for the duplicate case: drop the >1
  #    fatal (`allMatches.length > 1` -> `false`, so the guard never fires) and
  #    turn the single replace into a replace-all so EVERY --add-dir push loop
  #    gets the .asar filter (filtering .asar from any such loop is always safe).
  #
  # Both seds are inert on healthy single-match versions: the addTrustedFolder
  # exit path is never reached, the >1 guard was already false at 1 match, and
  # split/join == replace for a single occurrence. So no manual cleanup is
  # needed once upstream adapts these patches — the input tracks HEAD unpinned.
  claudeDesktopSrc = pkgs.applyPatches {
    name = "claude-desktop-debian-patch-failsafe";
    src = inputs.claude-desktop;
    postPatch = ''
      sed -i '/\[FAIL\] addTrustedFolder anchor not found/{n;s/process\.exit(1)/process.exit(0)/}' \
        scripts/patches/config.sh
      sed -i \
        -e 's/allMatches.length > 1/false/' \
        -e 's/code = code\.replace(match\[0\], filtered);/code = code.split(match[0]).join(filtered);/' \
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
      claude-desktop =
        let
          base = final.callPackage "${claudeDesktopSrc}/nix/claude-desktop.nix" {
            node-pty = final.callPackage "${claudeDesktopSrc}/nix/node-pty.nix" { };
          };
        in
        # Force GPU acceleration on. The launcher (launcher-common.sh) latches
        # into a persistent --disable-gpu mode the first time Chromium's GPU
        # process hits a FATAL (error_code=1002 -> "GPU process isn't usable.
        # Goodbye." — intermittent on this NVIDIA+Wayland+Electron stack), and
        # it counts its own "disabling GPU" marker as a re-trigger, so it never
        # self-recovers. Worse, this app version's --disable-gpu path also kills
        # the software rasterizer, so the "recovery" launch dies immediately
        # with an unhandled "GPU access not allowed" (exit 143) and no window
        # ever appears. The latch's fallback is therefore pure downside here.
        # CLAUDE_DISABLE_GPU=0 forces GPU on and bypasses the sticky check
        # (build_electron_args takes the `-v CLAUDE_DISABLE_GPU` branch, leaving
        # _disable_gpu=false and skipping _previous_launch_hit_gpu_fatal). The
        # launcher resolves its libs by absolute store path, so wrapping the
        # entrypoint is safe. Diagnosed 2026-06-26 after a reboot left the latch
        # tripped. Drop this wrap once upstream's recovery path stops disabling
        # the software rasterizer alongside the GPU.
        final.symlinkJoin {
          name = "claude-desktop-gpu-on-${base.version or ""}";
          paths = [ base ];
          nativeBuildInputs = [ final.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/claude-desktop --set CLAUDE_DISABLE_GPU 0
          '';
          inherit (base) meta;
        };
    })
  ];
  environment.systemPackages = [
    pkgs.claude-desktop
    inputs.claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
    # claude-code's `/voice` records the mic via sox's `rec` when its native
    # audio module doesn't load (the fallback path Diana hits). Recording only.
    pkgs.sox
  ];
}
