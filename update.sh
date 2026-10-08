#!/bin/bash
# Upgrade dictate from the repo without recreating the venv.
set -e

SCRIPT_DIR="$(dirname "$0")"
DATA_DIR="$HOME/.local/share/dictate"

# The venv is not touched, so refuse if the pinned dependencies changed
# since the last install.sh (or it predates install.sh recording the lock)
if ! cmp -s "$SCRIPT_DIR/requirements.lock" "$DATA_DIR/requirements.lock"; then
    echo "requirements.lock differs from the installed one (or install.sh predates it)."
    echo "Run instead: bash $SCRIPT_DIR/install.sh"
    exit 1
fi

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

    for s in dictate dictate-ptt dictate-server; do
        if systemctl --user is-active --quiet "$s"; then
            systemctl --user restart "$s"
            echo "Restarted $s"
        fi
    done
fi

git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null > "$DATA_DIR/version" || echo unknown > "$DATA_DIR/version"

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
