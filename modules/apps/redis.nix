{ ... }: {
  # --- REDIS (system-wide dev cache / broker) ---
  # Used by the lonchera backend for cache, Celery, and Channels. This is a
  # dev box, so we run a single unnamed server on loopback with NO on-disk
  # persistence — it's a cache, losing it on reboot is fine, and skipping RDB
  # snapshots means nothing has to survive the impermanence @root wipe.
  #
  # The unnamed server ("") produces redis.service listening on 127.0.0.1:6379
  # (matches redis://localhost:6379). Client tool (redis-cli) is already on
  # PATH via modules/apps/programming.nix.
  services.redis.servers."" = {
    enable = true;
    bind = "127.0.0.1";
    port = 6379;
    save = [ ];      # disable RDB snapshots — pure in-memory cache
  };
}
