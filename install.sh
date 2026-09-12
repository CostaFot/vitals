#!/usr/bin/env bash
# Install vitals. The user half needs no root; --with-smart adds the one
# system timer that does, because NVMe SMART attributes are root-only.
set -euo pipefail

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
  for unit in vitals-root.service vitals-root.timer; do
    "${SUDO[@]}" ln -sf "$REPO/systemd/$unit" /etc/systemd/system/"$unit"
  done
  "${SUDO[@]}" systemctl daemon-reload
  "${SUDO[@]}" systemctl enable --now vitals-root.timer
  echo "root timer installed: vitals-root.timer (hourly SMART read)"
else
  echo
  echo "SMART checks are off. They need root to read the drives:"
  echo "  ./install.sh --with-smart"
fi

echo
vitals status
