{ pkgs, ... }: {
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
    file
    poetry
    gh
    playwright-test
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
