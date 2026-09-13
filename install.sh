#!/usr/bin/env bash
# Install vitals. The user half needs no root; --with-smart adds the two root
# pieces: smartd, which watches the drives for an emergency, and the hourly
# timer that reads SMART attributes so the report has a trend.
set -euo pipefail

# smartd's '-H' reads the NVMe critical-warning byte - the drive's own verdict
# on failed health, spare blocks at the floor and passing its critical
# temperature. '<nomailer>' means run the script instead of sending mail, and
# 'daily' re-warns once a day for as long as the problem stands.
SMARTD_LINE='DEVICESCAN -H -l error -m <nomailer> -M daily -M exec /usr/local/bin/vitals-smartd-notify'

# Without a terminal to type into (running under an agent, or from a hotkey)
# sudo needs an askpass helper to put the prompt on screen.
SUDO=(sudo)
if [[ -n "${SUDO_ASKPASS:-}" && ! -t 0 ]]; then
  SUDO=(sudo -A)
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WITH_SMART=0
[[ "${1:-}" == "--with-smart" ]] && WITH_SMART=1

# --- user half ---------------------------------------------------------------

mkdir -p ~/.local/bin ~/.config/systemd/user
ln -sf "$REPO/vitals" ~/.local/bin/vitals

for unit in vitals.service vitals.timer; do
  ln -sf "$REPO/systemd/$unit" ~/.config/systemd/user/"$unit"
done

systemctl --user daemon-reload
systemctl --user enable --now vitals.timer
echo "user timer installed: vitals.timer (every minute)"

# --- root half ---------------------------------------------------------------

if (( WITH_SMART )); then
  "${SUDO[@]}" ln -sf "$REPO/vitals" /usr/local/bin/vitals
  # Copied, not symlinked. systemd builds the boot transaction before /home is
  # mounted, so a root unit symlinked into the repo is a dangling link at the
  # moment timers.target reads it, and the miss is cached for the rest of the
  # boot without a word in the journal. The user units can stay symlinks: that
  # manager starts at login, long after /home is up.
  for unit in vitals-root.service vitals-root.timer; do
    "${SUDO[@]}" install -m 644 "$REPO/systemd/$unit" /etc/systemd/system/"$unit"
  done
  "${SUDO[@]}" systemctl daemon-reload
  # reenable rather than enable, so an install that still has the old symlink
  # in timers.target.wants gets it rewritten to point at the copy.
  "${SUDO[@]}" systemctl reenable vitals-root.timer
  "${SUDO[@]}" systemctl start vitals-root.timer
  # One read now, which also anchors OnUnitActiveSec. A timer enabled on a
  # machine that booted more than a minute ago is already past its OnBootSec
  # point, and sits elapsed with nothing scheduled until the next boot unless
  # the service has run once to count an hour from.
  "${SUDO[@]}" systemctl start vitals-root.service
  echo "root timer installed: vitals-root.timer (hourly SMART read)"

  # smartd is the emergency tier. vitals does not duplicate it.
  "${SUDO[@]}" ln -sf "$REPO/smartd-notify" /usr/local/bin/vitals-smartd-notify
  if ! grep -qF vitals-smartd-notify /etc/smartd.conf 2>/dev/null; then
    "${SUDO[@]}" cp -n /etc/smartd.conf /etc/smartd.conf.before-vitals
    # Drop whatever DEVICESCAN shipped and put ours in its place, so running
    # this twice cannot stack two scan lines.
    "${SUDO[@]}" sed -i '/^[[:space:]]*DEVICESCAN/d' /etc/smartd.conf
    printf '%s\n' "$SMARTD_LINE" | "${SUDO[@]}" tee -a /etc/smartd.conf >/dev/null
  fi
  "${SUDO[@]}" systemctl enable --now smartd.service
  "${SUDO[@]}" systemctl reload smartd.service
  echo "smartd watching the drives, notifying through smartd-notify"
else
  echo
  echo "SMART checks are off. They need root to read the drives:"
  echo "  ./install.sh --with-smart"
fi

echo
vitals status
