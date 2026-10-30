{ ... }: {
  # --- NO SUSPEND, NO HIBERNATE, EVER ---
  #
  # Added 2026-10-30 for the paper-2 research seat, whose heavy jobs run unattended
  # 22:00-05:30. A suspend mid-run costs the night.
  #
  # MEASURED BEFORE CHANGING ANYTHING (2026-10-30): Diana already never suspended on
  # idle. logind `IdleAction=ignore`, GNOME `sleep-inactive-ac-type='nothing'`,
  # `idle-delay=0`, and zero sleep events across 30 days of journal. So the request's
  # "no suspend between 21:00 and 05:30" was already satisfied for the idle path, and
  # a time-windowed rule would have been new machinery guarding a door that was shut.
  #
  # What remained were two paths a window would not have closed either:
  #   - the physical power button. GNOME maps it to 'suspend'
  #     (`power-button-action`), and that beats logind's HandlePowerKey=poweroff
  #     while a graphical session is active.
  #   - a hand-run `systemctl suspend` from any shell.
  #
  # Masking the targets closes both, at any hour, with no window to get wrong and no
  # inhibitor process that can die. `suspend-then-hibernate` needs no separate entry:
  # it pulls in sleep.target and fails with it.
  #
  # Masking makes `systemctl suspend` fail LOUDLY rather than appear to work, which
  # is the behaviour we want if a person or an agent tries it.
  #
  # Screen LOCK is untouched: that is gnome-screensaver, not a sleep target. The
  # screen still blanks and locks normally.
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };
}
