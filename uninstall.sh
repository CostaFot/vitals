#!/usr/bin/env bash
# Remove everything install.sh put on the system. Leaves collected samples
# and the alert log in ~/.local/state/vitals alone.
set -euo pipefail

# Without a terminal to type into (running under an agent, or from a hotkey)
# sudo needs an askpass helper to put the prompt on screen.
SUDO=(sudo)
if [[ -n "${SUDO_ASKPASS:-}" && ! -t 0 ]]; then
  SUDO=(sudo -A)
fi

systemctl --user disable --now vitals.timer 2>/dev/null || true
rm -f ~/.config/systemd/user/vitals.service ~/.config/systemd/user/vitals.timer
rm -f ~/.local/bin/vitals
systemctl --user daemon-reload

if [[ -e /etc/systemd/system/vitals-root.timer ]]; then
  "${SUDO[@]}" systemctl disable --now vitals-root.timer 2>/dev/null || true
  "${SUDO[@]}" rm -f /etc/systemd/system/vitals-root.service \
             /etc/systemd/system/vitals-root.timer \
             /usr/local/bin/vitals
  "${SUDO[@]}" rm -rf /var/lib/vitals
  "${SUDO[@]}" systemctl daemon-reload
fi

# smartd is a system package, not ours. Put its config back and leave the
# daemon running - watching the drives is worth having with or without vitals.
if [[ -e /etc/smartd.conf.before-vitals ]]; then
  "${SUDO[@]}" mv /etc/smartd.conf.before-vitals /etc/smartd.conf
  "${SUDO[@]}" systemctl reload smartd.service 2>/dev/null || true
  echo "smartd.conf restored; smartd left running"
fi
"${SUDO[@]}" rm -f /usr/local/bin/vitals-smartd-notify

echo "removed. state kept in ~/.local/state/vitals"
