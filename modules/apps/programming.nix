{ pkgs, ... }: {
  # --- PROGRAMMING / DEV TOOLS ---
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
