{ config, pkgs, ... }: {
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
      # One role + database per cycle-hq seat. Before this, both seats' test
      # runs landed in the same test_lonchera and collided: on 2026-09-25 the
      # Operator's judge runs broke 120 of the Builder's gate tests, and the
      # seats were reduced to passing "DATABASE TAKEN / FREE" messages to hand
      # the database back and forth.
      #
      # Django derives its test database name from the connected one, so a
      # database per seat gives disjoint test_<name> and test_<name>_gwN sets
      # with no other coordination. createdb is required because pytest-django
      # creates and drops them per run.
      #
      # ensureDBOwnership matters on PostgreSQL 15+: `ensureDatabases` creates
      # the database owned by the superuser, and PG15 revoked CREATE on the
      # public schema for everyone but the owner. Verified on this box (PG 17.11)
      # with a probe role: it could create and fully use its TEST database
      # (it owns what it creates, so migrations are fine), but `CREATE TABLE` in
      # its own BASE database failed with "permission denied for schema public".
      # The test workflow works either way; ownership just stops the base
      # database being a dead end the first time someone tries to use it.
      { name = "lonchera_operator"; ensureClauses.createdb = true; ensureDBOwnership = true; }
      { name = "lonchera_builder";  ensureClauses.createdb = true; ensureDBOwnership = true; }
    ];
    ensureDatabases = [ "skirmitch" "lonchera_operator" "lonchera_builder" ];
  };

  # Client tools (psql, pg_dump, …) on PATH for everyone.
  environment.systemPackages = [ pkgs.postgresql_17 ];

  # --- DROP LEFTOVER PYTEST DATABASES ---
  #
  # lonchera/repos/backend/pytest.ini carries `addopts = --reuse-db -n auto`.
  # pytest-django then creates one database per xdist worker (test_<name>_gw0 …
  # _gw23) and, with --reuse-db, never drops any of them. Every agent run that
  # uses a fresh run name leaves up to 24 behind. Measured 2026-09-25: **777
  # leftover databases, 16 GiB**, accumulating 1-2 GiB/week. 751 were dropped by
  # hand; this keeps it from coming back.
  #
  # The real fix belongs in pytest.ini, but that is Ignacio's business code, so
  # the cleanup lives here instead.
  systemd.services.pg-drop-test-dbs = {
    description = "Drop leftover pytest-django test_* databases";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    path = [ config.services.postgresql.package ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
    };
    # The guard is the sub-select, not a process check. An open connection is
    # what actually blocks DROP DATABASE, so ask Postgres rather than grepping
    # for a running pytest: `pgrep -f '[p]ytest' || …` matches its own command
    # line whenever the literal word appears anywhere in it, short-circuits the
    # `||`, and silently does nothing. That exact bug cost us a day.
    #
    # test_lonchera, test_lonchera_operator, test_lonchera_builder and their
    # _gwN variants are the canonical --reuse-db sets and are deliberately kept
    # (the per-seat ones were added 2026-09-26; without widening this pattern
    # the timer would have silently dropped both seats' databases nightly).
    # Dropping them turns a warm 7 s test run into a full migration replay.
    script = ''
      psql -At -d postgres -c "select datname from pg_database
          where datname like 'test\_%'
            and datname !~ '^test_lonchera(_operator|_builder)?(_gw[0-9]+)?$'
            and datname not in (
              select datname from pg_stat_activity where datname is not null)" |
      while read -r db; do
        [ -n "$db" ] || continue
        dropdb --if-exists "$db" || echo "skipped (in use): $db"
      done
    '';
  };

  systemd.timers.pg-drop-test-dbs = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:30";
      # The stamp file lives in /var/lib/systemd/timers, which is persisted (see
      # hosts/diana/impermanence.nix) — without that, Persistent= is inert on
      # this box because the stamp is recreated empty at every boot.
      Persistent = true;
    };
  };
}
