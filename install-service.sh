#!/bin/bash
# Install and enable the dictate systemd user service.
set -e

mkdir -p ~/.config/systemd/user
cp "$(dirname "$0")/dictate.service" ~/.config/systemd/user/dictate.service
systemctl --user daemon-reload
systemctl --user enable --now dictate
echo ""
systemctl --user status dictate --no-pager
