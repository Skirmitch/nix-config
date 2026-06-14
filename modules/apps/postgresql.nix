{ pkgs, ... }: {
  # --- POSTGRESQL (system-wide dev database) ---
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;

    # Listen only on localhost — dev box, not a server.
    enableTCPIP = false;

    # Trust local connections so dev work "just works" without juggling
    # passwords. Safe because we only listen on the unix socket / loopback.
    authentication = pkgs.lib.mkOverride 10 ''
      # type  database  user  auth-method
      local   all       all   trust
      host    all       all   127.0.0.1/32  trust
      host    all       all   ::1/128       trust
    '';

    # Make our user a superuser and give it a matching database, so
    # `psql` with no args just connects.
    ensureUsers = [
      {
        name = "skirmitch";
        ensureClauses.superuser = true;
        ensureClauses.createdb = true;
      }
    ];
    ensureDatabases = [ "skirmitch" ];
  };

  # Client tools (psql, pg_dump, …) on PATH for everyone.
  environment.systemPackages = [ pkgs.postgresql_17 ];
}
