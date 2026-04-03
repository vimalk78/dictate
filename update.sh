#!/bin/bash
# Upgrade dictate from the repo without recreating the venv.
set -e

SCRIPT_DIR="$(dirname "$0")"

# Update main script
cp "$SCRIPT_DIR/dictate" ~/.local/share/dictate/dictate.py
echo "Updated dictate.py"

# Update launcher (ensure -u flag for unbuffered output)
LAUNCHER=~/.local/bin/dictate
if [ -f "$LAUNCHER" ] && ! grep -q 'python.*-u' "$LAUNCHER"; then
    sed -i 's|exec "\$VENV/bin/python"|exec "\$VENV/bin/python" -u|' "$LAUNCHER"
    echo "Updated launcher (added -u flag)"
fi

# Update editor wrapper if present
if [ -f "$SCRIPT_DIR/dictate-editor" ]; then
    cp "$SCRIPT_DIR/dictate-editor" ~/.local/bin/dictate-editor
    chmod +x ~/.local/bin/dictate-editor
fi

# Update service files and restart if services are active
if [ -d ~/.config/systemd/user ]; then
    cp "$SCRIPT_DIR/dictate.service" ~/.config/systemd/user/dictate.service
    cp "$SCRIPT_DIR/dictate-ptt.service" ~/.config/systemd/user/dictate-ptt.service
    systemctl --user daemon-reload

    if systemctl --user is-active --quiet dictate.service; then
        systemctl --user restart dictate.service dictate-ptt.service
        echo "Restarted services"
    fi
fi

# Update hints (don't overwrite user-edited files)
mkdir -p ~/.config/dictate/hints.d
for f in "$SCRIPT_DIR"/hints.d/*; do
    [ -f "$f" ] || continue
    dst=~/.config/dictate/hints.d/"$(basename "$f")"
    [ -f "$dst" ] || cp "$f" "$dst"
done

# Update Claude Code command
if [ -d ~/.claude/commands ]; then
    cp "$SCRIPT_DIR/dictate.claude-command" ~/.claude/commands/dictate.md 2>/dev/null || true
fi

echo "Upgrade complete."
