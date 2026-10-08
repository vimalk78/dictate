#!/bin/bash
# Remove everything install.sh created. Never uses sudo — system-level
# leftovers are printed as commands for you to run.
#
# Usage: bash uninstall.sh [--purge]
#   default  asks before deleting your config/hints/log and downloaded models
#   --purge  deletes those too, without asking
set -e

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

DATA_DIR="$HOME/.local/share/dictate"
HF_HUB="${HF_HOME:-$HOME/.cache/huggingface}/hub"

# ask <question> — yes with --purge, otherwise prompt (default no)
ask() {
    [ $PURGE -eq 1 ] && return 0
    read -p "$1 [y/N] " yn
    [[ "$yn" =~ ^[Yy] ]]
}

echo "=== dictate: uninstall ==="

# Services
if [ -d /run/systemd/system ] && command -v systemctl &>/dev/null; then
    systemctl --user disable --now dictate-ptt dictate 2>/dev/null || true
    rm -f ~/.config/systemd/user/dictate.service ~/.config/systemd/user/dictate-ptt.service
    systemctl --user daemon-reload 2>/dev/null || true
else
    rm -f ~/.config/systemd/user/dictate.service ~/.config/systemd/user/dictate-ptt.service
fi
echo "Removed services."

# Program files
rm -f ~/.local/bin/dictate ~/.local/bin/dictate-editor
rm -rf "$DATA_DIR/venv" "$DATA_DIR/wheels" "$DATA_DIR/__pycache__"
rm -f "$DATA_DIR/dictate.py" "$DATA_DIR/dictate.sock" "$DATA_DIR/dictate.pid" "$DATA_DIR/stop" \
      "$DATA_DIR/version" "$DATA_DIR/requirements.lock"
rm -f ~/.claude/commands/dictate.md
echo "Removed program files."

# User data
if [ -d ~/.config/dictate ] || [ -d "$DATA_DIR" ]; then
    if ask "Delete your config, vocabulary hints, and transcription log (~/.config/dictate, $DATA_DIR)?"; then
        rm -rf ~/.config/dictate "$DATA_DIR"
        echo "Removed config, hints, and log."
    else
        echo "Kept ~/.config/dictate and $DATA_DIR."
    fi
fi

# Downloaded Whisper models (shared Hugging Face cache — only dictate's models)
models=$(ls -d "$HF_HUB"/models--*faster-whisper* "$HF_HUB"/models--*faster-distil-whisper* 2>/dev/null || true)
if [ -n "$models" ]; then
    echo ""
    echo "Downloaded Whisper models:"
    du -sh $models | sed 's|^|  |'
    if ask "Delete these models?"; then
        rm -rf $models
        echo "Removed models."
    else
        echo "Kept models."
    fi
fi

# System-level leftovers (need sudo — print only)
echo ""
echo "Not removed (system-level; run yourself if you no longer need them):"
[ -f /usr/lib/systemd/system-sleep/dictate-resume ] && \
    echo "  sudo rm /usr/lib/systemd/system-sleep/dictate-resume"
id -nG "$USER" | grep -qw input && \
    echo "  sudo gpasswd -d $USER input    # if nothing else needs keyboard access"
echo "  # system packages from install.sh (uv, xsel, portaudio, ...) — other software may use them"
echo ""
echo "Done."
