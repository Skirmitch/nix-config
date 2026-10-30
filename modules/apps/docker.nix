{ ... }: {
  virtualisation.docker.enable = true;

  # --- ROOTLESS DOCKER, ALONGSIDE THE ROOT DAEMON ---
  #
  # Added 2026-10-30 for the paper-2 research seat (successor of midpowerroles),
  # which asked for a container runtime usable rootless by skirmitch. Additive by
  # design: the root daemon above and everything already under /var/lib/docker are
  # untouched. The rootless daemon is a separate per-user instance with its own
  # storage under ~/.local/share/docker, and it works here because
  # /etc/subuid and /etc/subgid already delegate skirmitch:100000:65536.
  #
  # `setSocketVariable` is deliberately LEFT OFF. It exports
  # DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock account-wide, which repoints
  # every `docker` invocation at the rootless daemon -- and the rootless daemon
  # cannot see /var/lib/docker, so JL's existing images and containers would appear
  # to have vanished. The brief for this change was explicitly "keeping the existing
  # daemon and images as they are", so the root daemon stays the default and the
  # research seat opts in per-shell:
  #
  #   DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock docker ...
  #
  # Flip it to true only as a deliberate, separate decision.
  #
  # NOT CHANGED, on purpose: skirmitch is in the `docker` group
  # (modules/system/users.nix), which is root-equivalent -- the group lets you
  # bind-mount / into a container as root. Enabling rootless does not revoke that,
  # and removing the group is JL's call, not this request's.
  virtualisation.docker.rootless.enable = true;
}
