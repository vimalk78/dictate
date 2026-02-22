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

# Install Python deps
echo "Installing Python packages..."
pip install -r "$(dirname "$0")/requirements.txt"

# Install the script
echo "Installing dictate to ~/.local/bin/"
mkdir -p ~/.local/bin
cp "$(dirname "$0")/dictate" ~/.local/bin/dictate
chmod +x ~/.local/bin/dictate

echo ""
echo "Done! Run: dictate"
echo "  Hold Right Ctrl to record, release to transcribe."
echo "  Ctrl+V to paste the transcribed text."
