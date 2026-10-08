#!/bin/bash
# Install and enable the dictate systemd user services.
set -e

mkdir -p ~/.config/systemd/user
cp "$(dirname "$0")/dictate.service" ~/.config/systemd/user/dictate.service
cp "$(dirname "$0")/dictate-ptt.service" ~/.config/systemd/user/dictate-ptt.service
systemctl --user daemon-reload
systemctl --user enable dictate dictate-ptt
# restart, not start: picks up new code if they were already running
systemctl --user restart dictate dictate-ptt
echo ""
systemctl --user status dictate dictate-ptt --no-pager
