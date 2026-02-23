#!/bin/bash
set -e

echo "=== dictate: push-to-talk voice input ==="

# Detect distro
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$ID"
else
    DISTRO="unknown"
fi

echo "Detected: $DISTRO"

# Install system deps
case "$DISTRO" in
    fedora)
        echo "Installing system packages..."
        sudo dnf install -y portaudio wl-clipboard
        # wtype may not be available on all Fedora versions
        sudo dnf install -y wtype 2>/dev/null || echo "wtype not available, clipboard-only mode"
        ;;
    ubuntu|debian)
        echo "Installing system packages..."
        sudo apt-get update
        sudo apt-get install -y libportaudio2 portaudio19-dev wl-clipboard wtype
        ;;
    *)
        echo "Unknown distro '$DISTRO'. Install manually: portaudio, wl-clipboard, wtype"
        ;;
esac

# Add user to input group (for evdev access without sudo)
if ! groups "$USER" | grep -q '\binput\b'; then
    echo "Adding $USER to input group..."
    sudo usermod -aG input "$USER"
    echo "NOTE: Log out and back in for group change to take effect."
fi

# Create venv and install Python deps
VENV_DIR="$HOME/.local/share/dictate/venv"
echo "Creating venv at $VENV_DIR..."
if command -v uv &>/dev/null; then
    PIP="uv pip"
    uv venv "$VENV_DIR"
else
    PIP="$VENV_DIR/bin/pip"
    python3 -m venv "$VENV_DIR"
fi
$PIP install --python "$VENV_DIR/bin/python" -r "$(dirname "$0")/requirements.txt"

# Install CUDA libs if NVIDIA GPU is present
if command -v nvidia-smi &>/dev/null; then
    echo "NVIDIA GPU detected, installing CUDA libraries..."
    $PIP install --python "$VENV_DIR/bin/python" nvidia-cublas-cu12
fi

# Install launcher script
echo "Installing dictate to ~/.local/bin/"
mkdir -p ~/.local/bin
NVIDIA_LIBS="$VENV_DIR/lib64/python*/site-packages/nvidia/cublas/lib"
cat > ~/.local/bin/dictate <<LAUNCHER
#!/bin/bash
VENV="$VENV_DIR"
for d in $NVIDIA_LIBS; do
    [ -d "\$d" ] && export LD_LIBRARY_PATH="\$d\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
done
exec "\$VENV/bin/python" "$HOME/.local/share/dictate/dictate.py" "\$@"
LAUNCHER
chmod +x ~/.local/bin/dictate

# Copy the actual script and editor wrapper
cp "$(dirname "$0")/dictate" "$HOME/.local/share/dictate/dictate.py"
cp "$(dirname "$0")/dictate-editor" ~/.local/bin/dictate-editor
chmod +x ~/.local/bin/dictate-editor

# Install default config (don't overwrite existing)
mkdir -p ~/.config/dictate
if [ ! -f ~/.config/dictate/config.toml ]; then
    cp "$(dirname "$0")/config.toml.example" ~/.config/dictate/config.toml
    echo "Created config at ~/.config/dictate/config.toml"
fi

# Install global hints
mkdir -p ~/.config/dictate/hints.d
cp "$(dirname "$0")"/hints.d/* ~/.config/dictate/hints.d/ 2>/dev/null || true
echo "Installed global hints to ~/.config/dictate/hints.d/"

# Install Claude Code integration
mkdir -p ~/.claude/commands
cp "$(dirname "$0")/dictate.claude-command" ~/.claude/commands/dictate.md
echo "Installed /dictate command for Claude Code."

echo ""
echo "Done! Run: dictate"
echo "  Hold Right Ctrl to record, release to transcribe."
echo "  Ctrl+V to paste the transcribed text."
echo "  Edit ~/.config/dictate/config.toml to customize."
echo ""
echo "Claude Code integration:"
echo "  1. Start daemon:  dictate --serve"
echo "  2. Launch Claude:  EDITOR=dictate-editor claude"
echo "  3. Use /dictate to speak, or Ctrl+G then F5 to dictate in editor"
echo ""
if grep -q "^input:.*\b$USER\b" /etc/group && ! id -nG 2>/dev/null | grep -qw input; then
    echo "⚠ IMPORTANT: Log out and back in for input group membership to take effect."
    echo "  Without this, dictate cannot detect key presses."
fi
