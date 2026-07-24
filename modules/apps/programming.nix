{ pkgs, ... }:
let
  # Generation-stable path to the Nix-patched Chromium that ships with
  # playwright-test's browser bundle. The Playwright MCP (npx @playwright/mcp)
  # defaults to the "chrome" channel = /opt/google/chrome, which can't exist
  # on NixOS — its config instead passes
  # --executable-path /run/current-system/sw/bin/playwright-chromium,
  # which this keeps pointing at the current bundle across nixpkgs bumps.
  playwright-chromium-bin = pkgs.runCommand "playwright-chromium-bin" { } ''
    mkdir -p $out/bin
    chrome=$(echo ${pkgs.playwright-driver.browsers}/chromium-*/chrome-linux*/chrome)
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
    playwright-test
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
}
