{ pkgs, ... }:
let
  # --- PLAYWRIGHT: CHROMIUM ONLY ---
  #
  # nixpkgs' playwright browser bundle builds chromium + firefox + webkit, and
  # on the nixpkgs locked 2026-09-17 playwright-webkit does not build at all:
  # auto-patchelf cannot satisfy libmanette-0.2.so.0, wanted by
  # libWPEWebKit-2.0.so.1.12.0 (the WPE port links the gamepad library, the
  # derivation does not list it). That failure propagates through
  # playwright-browsers -> playwright-test -> system-path -> toplevel, so a
  # plain `dif` could not build the system at all.
  #
  # Upstream fixed it on master on 2026-09-16 ("playwright-webkit: add missing
  # libmanette", 67bf9043b1) but the fix had NOT reached the nixos-unstable
  # channel this flake follows as of the locked rev a32edd765.
  #
  # The fix here is not a workaround though, it is what this machine actually
  # wants: nothing on Diana has ever driven firefox or webkit. The Playwright
  # MCP (npx @playwright/mcp) drives chromium and only chromium. So both
  # consumers below are pinned to the chromium-only bundle, which dodges the
  # broken derivation, cuts the closure, and makes future firefox/webkit
  # breakage unable to take the system build down. Revisit only if something
  # ever genuinely needs the other two engines.

  # playwright-test is the `playwright` CLI. Its wrapper bakes
  # PLAYWRIGHT_BROWSERS_PATH to playwright-core.passthru.browsers -- the FULL
  # bundle -- and that attribute is not overridable from outside, so the CLI
  # is rebuilt from a copy of the nixpkgs expression whose wrapper points at
  # browsers-chromium instead. --replace-fail makes this die loudly if
  # upstream restructures driver.nix, rather than silently handing back a CLI
  # with no browsers.
  playwrightDriverSrc = pkgs.runCommand "playwright-driver-src-chromium-only" { } ''
    cp -r ${pkgs.path}/pkgs/development/web/playwright $out
    chmod -R u+w $out
    substituteInPlace $out/driver.nix \
      --replace-fail \
        'PLAYWRIGHT_BROWSERS_PATH "''${playwright-core.passthru.browsers}"' \
        'PLAYWRIGHT_BROWSERS_PATH "''${playwright-core.passthru.browsers-chromium}"'
  '';
  playwright-test-chromium =
    (pkgs.callPackage "${playwrightDriverSrc}/driver.nix" { }).playwright-test;

  # Generation-stable path to the Nix-patched Chromium in that bundle. The
  # Playwright MCP defaults to the "chrome" channel = /opt/google/chrome,
  # which cannot exist on NixOS -- its config instead passes
  # --executable-path /run/current-system/sw/bin/playwright-chromium, which
  # this keeps pointing at the current bundle across nixpkgs bumps.
  playwright-chromium-bin = pkgs.runCommand "playwright-chromium-bin" { } ''
    mkdir -p $out/bin
    chrome=$(echo ${pkgs.playwright-driver.browsers-chromium}/chromium-*/chrome-linux*/chrome)
    [ -x "$chrome" ] || { echo "no chromium in playwright browsers bundle" >&2; exit 1; }
    ln -s "$chrome" $out/bin/playwright-chromium
  '';

  # virtualenv 21 dropped the bundled pip/setuptools seed wheels for Python
  # < 3.9 (BUNDLE_SUPPORT now starts at 3.9). Poetry's test suite builds its
  # fake interpreter with MockEnv(version_info=(3, 7, 0)), so get_embed_wheel
  # returns None and poetry raises "embedded pip wheel not found" — three
  # tests in tests/installation/test_executor.py fail and take the whole
  # system-path build down with them.
  #
  # Verified test-only: get_embed_wheel("pip", v) resolves fine for every
  # real interpreter (3.9 -> pip-26.0.1, 3.13/3.14 -> pip-26.1.2) and only
  # returns None for the fictional 3.7/3.8. The poetry binary is unaffected.
  # Drop this once upstream poetry stops pinning MockEnv to 3.7.
  poetry-skip-py37-mockenv-tests = pkgs.poetry.overridePythonAttrs (old: {
    disabledTests = (old.disabledTests or [ ]) ++ [
      "test_execute_executes_a_batch_of_operations"
      "test_execute_prints_warning_for_yanked_package"
    ];
  });
in
{
  # --- PROGRAMMING / DEV TOOLS ---

  # Run dynamically-linked binaries from Poetry/pip wheels (manylinux PIEs that
  # request /lib64/ld-linux-x86-64.so.2, which NixOS doesn't provide). Without
  # this, `poetry run ruff` etc. die with "Could not start dynamically linked
  # executable". Lets the project's pinned ruff 0.4.10 run for CI parity instead
  # of falling back to the nixpkgs `ruff` below (0.15.x — disagrees with CI).
  programs.nix-ld.enable = true;

  environment.systemPackages = with pkgs; [
    vscode
    awscli2
    ssm-session-manager-plugin
    nodejs
    jetbrains.rust-rover
    sqlite
    duckdb
    file
    poetry-skip-py37-mockenv-tests
    gh
    playwright-test-chromium
    playwright-chromium-bin
    shellcheck
    sentry-cli
    openssl

    # Django / Python
    gettext        # msgfmt for makemessages/compilemessages (i18n)
    ruff           # python linter + formatter
    pre-commit     # git hook runner
    redis          # redis-cli + redis-server for cache/Celery/Channels
    httpie         # friendly REST client

    # JS frontend
    bun            # runtime + package manager + bundler
  ];

  # --- PLAYWRIGHT BROWSERS FOR THE CYCLE SEATS ---
  #
  # Operator asked for `playwright-driver.browsers` so the seats can run
  # end-to-end tests of the admin planogram editor. That package is the one
  # thing this module exists to avoid: it builds chromium + firefox + webkit,
  # and playwright-webkit's auto-patchelf failure on libmanette (2026-09-18)
  # propagated into system-path and toplevel, which broke rebuilds outright.
  #
  # `browsers-chromium` gives the seats what they actually need with none of
  # that risk, and it is the same bundle the CLI and MCP already drive. If
  # cross-browser coverage is ever genuinely required, build-test
  # playwright-driver.browsers on its own FIRST - it evaluates on this pin,
  # which is not the same as building.
  #
  # Pin @playwright/test to ${pkgs.playwright-driver.version} in any repo that
  # uses this, or the JS client and the browser bundle drift apart.
  environment.sessionVariables = {
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.selectBrowsers {
      withFirefox = false;
      withWebkit = false;
      withChromiumHeadlessShell = true;
    }}";
    # nixpkgs' chromium is already patched for NixOS; playwright's own host
    # validation looks for distro packages that do not exist here.
    PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
  };
}
