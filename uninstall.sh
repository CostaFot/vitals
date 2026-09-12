#!/usr/bin/env bash
# Remove everything install.sh put on the system. Leaves collected samples
# and the alert log in ~/.local/state/vitals alone.
set -euo pipefail

systemctl --user disable --now vitals.timer 2>/dev/null || true
rm -f ~/.config/systemd/user/vitals.service ~/.config/systemd/user/vitals.timer
rm -f ~/.local/bin/vitals
systemctl --user daemon-reload

if [[ -e /etc/systemd/system/vitals-root.timer ]]; then
  sudo systemctl disable --now vitals-root.timer 2>/dev/null || true
  sudo rm -f /etc/systemd/system/vitals-root.service \
             /etc/systemd/system/vitals-root.timer \
             /usr/local/bin/vitals
  sudo rm -rf /var/lib/vitals
  sudo systemctl daemon-reload
fi

echo "removed. state kept in ~/.local/state/vitals"
