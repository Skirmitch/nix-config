{ config, lib, pkgs, ... }:
let
  seats = config.cycle.seats or { };
  roles = lib.mapAttrsToList (_: s: s.dbRole) seats;
  # The exemption pattern is GENERATED. Shipped by hand as `(_operator|_builder)` it
  # would have silently dropped a third seat's test databases at 04:30 - both seats
  # independently warned about exactly this, and Constructor and Seba folders exist.
  suffixAlt = lib.concatStringsSep "|" (map (r: lib.removePrefix "lonchera" r) roles);
in {
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
    ] ++ map (r: { name = r; ensureClauses.createdb = true; ensureDBOwnership = true; }) roles;
    ensureDatabases = [ "skirmitch" ] ++ roles;
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
  # --- COLLATION VERSION CHECK: learn at REBUILD time, not from a red test run -----
  #
  # PostgreSQL does not sort text itself; it asks glibc. So a text index is physically
  # ordered by glibc's rules AT THE MOMENT IT WAS BUILT, and Postgres records which
  # glibc version that was. When a rebuild moves glibc, every database still recording
  # the old number warns, and `CREATE DATABASE` FAILS outright because it reads
  # template1. That is inherent to a glibc-provided collation and nothing in this
  # config can prevent it - pinning glibc would be worse than the disease.
  #
  # 2026-10-02 it happened for real: glibc 2.42 -> 2.44 arrived with generation 267 and
  # `CREATE DATABASE` started failing. JL found out hours later, from a seat's proofs
  # going red, looking like a mysterious test failure; three sessions were pulled in to
  # identify a two-minute fix. THIS UNIT DOES NOT FIX ANYTHING. It moves the discovery
  # to the moment the cause is obvious. A smoke detector, not a sprinkler.
  #
  # TWO COMPARISONS, AND THE SECOND IS THE ONE THAT MATTERS.
  # `ALTER DATABASE x REFRESH COLLATION VERSION` updates pg_database and does NOT touch
  # that database's own pg_collation rows. So a database can record a CURRENT version
  # while carrying stale collations - and every database created from such a template
  # inherits them. Measured on the day: after template1's database version was
  # refreshed but before its collations were, test_vfy_u1001a_532_685989ff read
  # datcollversion 2.44 with FOUR stale collation rows. A check reading only
  # pg_database would have called that healthy, which is the failure shape this whole
  # module keeps producing: an instrument reporting health while the thing it measures
  # is wrong. Hence the per-database sweep. It costs 626 ms over 69 databases.
  #
  # IT NEVER WRITES. Refreshing without reindexing first is the actual hazard: it
  # updates a number and deletes the only warning that an index is mis-ordered. The
  # remedy is REINDEX then REFRESH, in that order, run by a human who has read it.
  #
  # NO EXEMPTION LIST, by both seats' choice. An exemption would mean this unit and
  # pg-drop-test-dbs each carrying a pattern that must agree forever, and this module
  # has already produced that class of bug. The seats clean their own test databases
  # instead - Builder ruled his disposable and reindexable or droppable at will.
  #
  # Visible in `systemctl --failed`, at Builder's request: nothing on either seat's
  # ship path reads it, so a red unit cannot interrupt a push, and it belongs where a
  # human sees it.
  systemd.services.cycle-pg-collation-check = {
    description = "Report PostgreSQL collation versions that no longer match glibc";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.services.postgresql.package pkgs.coreutils ];
    # RE-RUN EXACTLY WHEN IT MATTERS. The trigger is glibc's own store path, so a
    # rebuild that moves glibc re-runs this one and a rebuild that does not, does not.
    # Without it a oneshot only re-runs when its own text changes, which is never the
    # thing that breaks collation.
    restartTriggers = [ "${pkgs.glibc}" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      set -uo pipefail

      dbbad=$(psql -tAq -d postgres -c "
        select datname || '  recorded ' || datcollversion || ', OS provides ' ||
               pg_database_collation_actual_version(oid)
        from pg_database
        where datcollversion is not null
          and datcollversion <> pg_database_collation_actual_version(oid)
        order by datname") || { echo "REFUSE: could not query pg_database"; exit 2; }

      # COULD NOT LOOK IS NOT HEALTHY, and a run must PRINT ITS DENOMINATOR (both at
      # Operator's ask). The first draft of this loop ended `|| continue`, which skips a
      # database it cannot read and then reports success - a guard that refuses in
      # silence. It now counts what it read, what it skipped and why, prints those on
      # every run, and exits 3 rather than 0 when anything was unreadable.
      dbs_total=$(psql -tAq -d postgres -c "select count(*) from pg_database") || dbs_total=""
      dbs_versioned=$(psql -tAq -d postgres -c \
        "select count(*) from pg_database where datcollversion is not null") || dbs_versioned=""
      dbs_noversion=$(psql -tAq -d postgres -c \
        "select string_agg(datname, ', ') from pg_database where datcollversion is null") || dbs_noversion=""

      # The second comparison. Per database, because pg_collation is per database.
      collbad=""; read_ok=0; rows_read=0; unread=""
      for db in $(psql -tAq -d postgres -c \
          "select datname from pg_database where datallowconn order by datname"); do
        n=$(psql -tAq -d "$db" -c \
          "select count(*) from pg_collation
           where collprovider='c' and collversion is not null
             and collversion <> pg_collation_actual_version(oid)" 2>/dev/null)
        rc=$?
        if [ "$rc" != 0 ] || [ -z "$n" ]; then
          unread="$unread  $db  (could not read its pg_collation, psql rc=$rc)
"
          continue
        fi
        read_ok=$((read_ok + 1))
        tot=$(psql -tAq -d "$db" -c \
          "select count(*) from pg_collation where collprovider='c' and collversion is not null" 2>/dev/null) || tot=0
        rows_read=$((rows_read + tot))
        if [ "$n" != 0 ]; then
          collbad="$collbad  $db  $n stale collation row(s)
"
        fi
      done

      # THE DENOMINATOR, on every run, pass or fail. A run that read nothing must not be
      # indistinguishable from a run that found nothing.
      echo "read: $dbs_versioned of $dbs_total databases carry a recorded version;"
      echo "      $rows_read collation rows across $read_ok connectable databases."
      [ -n "$dbs_noversion" ] && echo "      no recorded version, by design: $dbs_noversion"
      [ -n "$unread" ] && { echo "      UNREADABLE:"; printf '%s' "$unread"; }

      if [ -z "$dbs_versioned" ] || [ "$dbs_versioned" = 0 ] || [ "$read_ok" = 0 ]; then
        echo "REFUSE: read nothing to judge. That is not a pass."
        exit 3
      fi
      if [ -n "$unread" ]; then
        echo "REFUSE: some databases could not be read, so this run cannot clear them."
        exit 3
      fi

      if [ -z "$dbbad" ] && [ -z "$collbad" ]; then
        echo "collation versions match glibc in every database read above."
        exit 0
      fi

      echo "COLLATION VERSION MISMATCH. glibc moved and these databases still record the old one."
      [ -n "$dbbad" ] && { echo; echo "database-level:"; printf '%s\n' "$dbbad" | sed 's/^/  /'; }
      [ -n "$collbad" ] && { echo; echo "stale pg_collation rows (a REFRESH of the database does NOT fix these):"; printf '%s' "$collbad"; }
      cat <<'EOT'

REMEDY, IN THIS ORDER. Reversing it hides index corruption instead of fixing it:

  psql -U postgres -d <db> -c 'REINDEX DATABASE "<db>";'
  psql -U postgres -d <db> -c 'DO $$ DECLARE c record; BEGIN
      FOR c IN SELECT oid::regcollation AS cn FROM pg_collation
               WHERE collprovider = 'c' AND collversion IS NOT NULL
                 AND collversion <> pg_collation_actual_version(oid)
      LOOP EXECUTE format('ALTER COLLATION %s REFRESH VERSION', c.cn); END LOOP;
    END $$;'
  psql -U postgres -d postgres -c 'ALTER DATABASE "<db>" REFRESH COLLATION VERSION;'

Do template1 FIRST: until it is clean, CREATE DATABASE fails and every new database is
born stale. template0 needs nothing - it records no version by design.
Disposable test databases can simply be dropped; the next run recreates them clean.
EOT
      exit 1
    '';
  };

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
            and datname !~ '^test_lonchera(${suffixAlt})?(_gw[0-9]+)?$'
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
