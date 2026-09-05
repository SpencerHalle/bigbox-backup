#!/usr/bin/env bash
# Install / refresh the bigbox-backup systemd --user timer.
# Safe to re-run after editing the unit files.
set -e
cd "$(dirname "$0")"

chmod +x backup.sh
mkdir -p ~/.config/systemd/user
cp bigbox-backup.service ~/.config/systemd/user/bigbox-backup.service
cp bigbox-backup.timer   ~/.config/systemd/user/bigbox-backup.timer

systemctl --user daemon-reload
systemctl --user enable --now bigbox-backup.timer
loginctl enable-linger "$USER" 2>/dev/null || true   # runs even when logged out

echo
systemctl --user list-timers bigbox-backup.timer --no-pager || true
echo
echo "run once now:  systemctl --user start bigbox-backup.service"
echo "watch:         journalctl --user -u bigbox-backup -f"
