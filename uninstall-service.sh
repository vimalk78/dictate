#!/bin/bash
# Stop, disable, and remove the dictate systemd user service.
set -e

systemctl --user disable --now dictate 2>/dev/null || true
rm -f ~/.config/systemd/user/dictate.service
systemctl --user daemon-reload
echo "dictate service removed."
