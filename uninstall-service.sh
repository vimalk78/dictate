#!/bin/bash
# Stop, disable, and remove the dictate systemd user services.
set -e

systemctl --user disable --now dictate-ptt 2>/dev/null || true
systemctl --user disable --now dictate 2>/dev/null || true
rm -f ~/.config/systemd/user/dictate.service ~/.config/systemd/user/dictate-ptt.service
systemctl --user daemon-reload
echo "dictate services removed."
