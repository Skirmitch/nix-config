{ pkgs, ... }:
let
  # Zerene Stacker — focus stacking for the macro/microscope work (a7RV, OM-5,
  # Lumix G9 on the Leica S9D). Not in nixpkgs (checked 2026-09-18), so this
  # packages the vendor's own Linux build.
  #
  # LICENSING: the download is the full program; with no key it runs in a
  # 30-day trial and a purchased key unlocks it for good ("There is really only
  # one version of the software... Installing a license key unlocks features
  # for unlimited use" — the downloads page). So this derivation is the whole
  # install; licensing needs no rebuild, just Options > Registration.
  #
  # State lives in ~/.ZereneStacker/: LicenseKey.txt (the licence itself),
  # zerenstk.cfg (preferences, including the -Xmx the launcher synthesises),
  # zerenstk.launchcmd and any JVM crash dumps. That is on /home, which is its
  # own btrfs subvolume (@home) and is never touched by the initrd rollback in
  # hosts/diana/impermanence.nix — verified, so no persist entry is needed.
  # Zerene also supports a system-wide LicenseKey.txt next to the jar; that one
  # cannot work here because the store is read-only. Use the per-user path.
  #
  # PRIVACY: the jar hardcodes calls to zerenesystems.com PeekLatestUpdate.php
  # (update check) and LogEvent.php (telemetry). Both can be silenced by
  # setting AutoUpdateCheck.IntervalInDays=0.0 in ~/.ZereneStacker/zerenstk.cfg.
  #
  # TO UPDATE: the version string is a build stamp. Read the current one off
  #   https://zerenesystems.com/cms/stacker/softwaredownloads
  # and bump `version` + `hash` below. Old builds stay served from the same
  # /stacker/downloads/ path, so the pin does not rot.
  version = "T2026-05-04-0750";

  # The upstream zip ships a vendored Azul Zulu 25.0.1 JRE. We drop it and use
  # nixpkgs' jdk25 (25.0.4.1 — same feature release) instead, which is exactly
  # what the vendor's Linux notes allow: "If you want to use a JRE other than
  # the one provided with the distribution, just edit the zerenstk.ini template
  # as desired." Reason: the app is Swing/AWT, so its JRE needs X11, freetype
  # and fontconfig wired up correctly -- nixpkgs' JDK already has that, whereas
  # autoPatchelf'ing ~30 vendored JRE objects would mean re-deriving all of it
  # by hand and would never see a security update.
  jdk = pkgs.jdk25;

  zerene-stacker = pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "zerene-stacker";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://zerenesystems.com/stacker/downloads/ZS-Linux-Intel-64bit-${finalAttrs.version}.zip";
      hash = "sha256-PUCHbO780F9pT5SzysJsPT7/EMPDWw+R70U6emllRX0=";
    };

    nativeBuildInputs = with pkgs; [
      unzip
      autoPatchelfHook
      makeWrapper
      copyDesktopItems
      imagemagick
      perl # the only icons shipped are .gif, inside the jar
    ];

    # ZereneStacker (the launcher) needs only libc; StackShotHelper.zslinux
    # (the StackShot macro-rail driver) also wants libstdc++.
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];

    # perl must be present for patchShebangs to resolve the bundled exiftool's
    # /usr/bin/perl shebang, which does not exist on NixOS.
    propagatedBuildInputs = [ pkgs.perl ];

    # tiffReadZS.zslinux is a 32-bit STATIC binary, so there is nothing to
    # patch and no 32-bit loader to find; autoPatchelf would otherwise trip.
    autoPatchelfIgnoreMissingDeps = true;

    sourceRoot = "ZereneStacker";

    installPhase = ''
      runHook preInstall

      appdir=$out/share/zerene-stacker
      mkdir -p $appdir
      cp -r . $appdir/

      # Vendored JRE is replaced by ${jdk} (see the note above).
      rm -rf $appdir/jre

      # The launch template is what the native launcher expands at startup; it
      # is the single place the JRE is named. --replace-fail so a repackaged
      # upstream ini breaks the build loudly instead of silently shipping a
      # launcher that cannot find java.
      substituteInPlace $appdir/zerenstk.ini \
        --replace-fail '"{appdir}/jre/bin/java"' '"${jdk}/bin/java"'

      chmod +x $appdir/ZereneStacker $appdir/ZereneStacker.bsh $appdir/*.zslinux

      # Bundled exiftool is a Perl distribution with a /usr/bin/perl shebang.
      patchShebangs $appdir/exiftool

      # The launcher resolves its own directory, so it must be exec'd in place
      # rather than symlinked into bin.
      makeWrapper $appdir/ZereneStacker $out/bin/zerene-stacker

      # Desktop entry + icons. The only artwork upstream ships is three .gif
      # files inside the jar, so convert them to the PNG the icon spec wants.
      for size in 16 32 64; do
        unzip -p $appdir/ZereneStacker.jar \
          com/zerenesystems/stacker/gui/icons/''${size}x''${size}.gif > icon.gif
        install -Dm644 /dev/null $out/share/icons/hicolor/''${size}x''${size}/apps/zerene-stacker.png
        magick icon.gif $out/share/icons/hicolor/''${size}x''${size}/apps/zerene-stacker.png
      done

      runHook postInstall
    '';

    desktopItems = [
      (pkgs.makeDesktopItem {
        name = "zerene-stacker";
        desktopName = "Zerene Stacker";
        comment = "Focus stacking for macro and microscope photography";
        exec = "zerene-stacker";
        icon = "zerene-stacker";
        categories = [ "Graphics" "Photography" ];
      })
    ];

    meta = {
      description = "Focus stacking software for macro and microscope photography";
      homepage = "https://zerenesystems.com/cms/stacker";
      # Proprietary: 30-day trial, then a purchased licence key.
      license = pkgs.lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
      mainProgram = "zerene-stacker";
    };
  });
in
{
  # --- ZERENE STACKER (focus stacking) ---
  environment.systemPackages = [ zerene-stacker ];
}
