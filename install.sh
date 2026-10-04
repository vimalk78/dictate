#!/bin/bash
set -e

echo "=== dictate: push-to-talk voice input ==="

ARCH=$(uname -m)
SCRIPT_DIR="$(dirname "$0")"
VENV_DIR="$HOME/.local/share/dictate/venv"
WHEEL_DIR="$HOME/.local/share/dictate/wheels"
# System Python, not whatever is first on PATH (e.g. conda)
PYTHON=/usr/bin/python3

# Detect distro
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$ID"
else
    DISTRO="unknown"
fi

echo "Detected: $DISTRO ($ARCH)"

# ── Requirements check ───────────────────────────────────────────
# Check everything up front and change nothing. If anything is missing,
# print what to run and exit — this script never uses sudo.

MISSING=()      # human-readable descriptions
PKGS=()         # distro packages that fix them
EXTRA_CMDS=()   # fixes that aren't a package install

# require <description> <check command> <fedora pkg> <ubuntu/debian pkg>
require() {
    local desc="$1" check="$2" fedora_pkg="$3" debian_pkg="$4"
    if ! eval "$check" &>/dev/null; then
        MISSING+=("$desc")
        case "$DISTRO" in
            fedora) PKGS+=("$fedora_pkg") ;;
            ubuntu|debian) PKGS+=("$debian_pkg") ;;
            *) PKGS+=("$fedora_pkg") ;;
        esac
    fi
}

require "Python 3.10+ ($PYTHON)" \
    "$PYTHON -c 'import sys; sys.exit(sys.version_info < (3, 10))'" python3 python3
# evdev has no binary wheels on PyPI — it compiles a C extension
require "C compiler (gcc, to build evdev)" "command -v gcc" gcc gcc
require "Python headers (Python.h, to build evdev)" \
    "$PYTHON -c 'import os, sys, sysconfig; sys.exit(not os.path.exists(os.path.join(sysconfig.get_path(\"include\"), \"Python.h\")))'" \
    python3-devel python3-dev
require "Linux input headers (to build evdev)" \
    "test -f /usr/include/linux/input.h" kernel-headers linux-libc-dev
require "PortAudio library (audio capture)" \
    "ldconfig -p | grep -q libportaudio.so.2" portaudio libportaudio2
require "xsel (clipboard)" "command -v xsel" xsel xsel
require "pw-play (completion sounds)" "command -v pw-play" pipewire-utils pipewire-bin
require "notify-send (desktop notifications)" "command -v notify-send" libnotify libnotify-bin

# uv is not packaged for Ubuntu/Debian — use the upstream installer there
if ! command -v uv &>/dev/null; then
    MISSING+=("uv (Python package manager)")
    case "$DISTRO" in
        fedora) PKGS+=("uv") ;;
        *)
            command -v curl &>/dev/null || PKGS+=("curl")
            EXTRA_CMDS+=("curl -LsSf https://astral.sh/uv/install.sh | sh")
            ;;
    esac
fi

# input group: needed to read the keyboard via evdev (push-to-talk)
if ! id -nG "$USER" | grep -qw input; then
    MISSING+=("membership in the 'input' group (push-to-talk key detection)")
    EXTRA_CMDS+=("sudo usermod -aG input $USER    # then log out and back in")
elif ! id -nG | grep -qw input; then
    MISSING+=("'input' group not active in this session")
    EXTRA_CMDS+=("# log out and back in (or reboot), then re-run this script")
fi

# Jetson: needs a ctranslate2 wheel built from source
if [ "$ARCH" = "aarch64" ] && ! ls "$WHEEL_DIR"/ctranslate2*.whl &>/dev/null; then
    MISSING+=("ctranslate2 wheel for aarch64 in $WHEEL_DIR/")
    EXTRA_CMDS+=("bash $SCRIPT_DIR/build-ctranslate2.sh")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo "Missing requirements:"
    for m in "${MISSING[@]}"; do
        echo "  - $m"
    done
    echo ""
    echo "To fix, run:"
    if [ ${#PKGS[@]} -gt 0 ]; then
        case "$DISTRO" in
            fedora) echo "  sudo dnf install ${PKGS[*]}" ;;
            ubuntu|debian) echo "  sudo apt-get install ${PKGS[*]}" ;;
            *) echo "  install packages (Fedora names): ${PKGS[*]}" ;;
        esac
    fi
    for c in "${EXTRA_CMDS[@]}"; do
        echo "  $c"
    done
    echo ""
    echo "Then re-run: bash $0"
    exit 1
fi

echo "All requirements met."

# ── Install ──────────────────────────────────────────────────────

echo "Creating venv at $VENV_DIR..."
uv venv --clear --python "$PYTHON" "$VENV_DIR"
PIP_INSTALL="uv pip install --python $VENV_DIR/bin/python"

# Exact versions (generated from requirements.txt — see header of requirements.lock)
if [ "$ARCH" = "aarch64" ]; then
    # Jetson: the locally built CUDA ctranslate2 wheel replaces the lock's
    # ctranslate2 pin — otherwise uv swaps it for PyPI's CPU-only wheel.
    WHEEL=$(ls "$WHEEL_DIR"/ctranslate2*.whl | head -1)
    echo "Using pre-built ctranslate2 wheel: $(basename "$WHEEL")"
    LOCK_NO_CT2=$(mktemp)
    grep -v '^ctranslate2==' "$SCRIPT_DIR/requirements.lock" > "$LOCK_NO_CT2"
    $PIP_INSTALL "$WHEEL" -r "$LOCK_NO_CT2"
    rm -f "$LOCK_NO_CT2"
else
    $PIP_INSTALL -r "$SCRIPT_DIR/requirements.lock"
fi

# Install CUDA libs if NVIDIA GPU is present (x86_64 only — Jetson uses JetPack system CUDA)
if [ "$ARCH" != "aarch64" ] && command -v nvidia-smi &>/dev/null; then
    echo "NVIDIA GPU detected, installing CUDA libraries..."
    $PIP_INSTALL nvidia-cublas-cu12
fi

# Install launcher script
echo "Installing dictate to ~/.local/bin/"
mkdir -p ~/.local/bin
if [ "$ARCH" = "aarch64" ]; then
    cat > ~/.local/bin/dictate <<LAUNCHER
#!/bin/bash
VENV="$VENV_DIR"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$VENV/bin/python" -u "$HOME/.local/share/dictate/dictate.py" "\$@"
LAUNCHER
else
    NVIDIA_LIBS="$VENV_DIR/lib64/python*/site-packages/nvidia/cublas/lib"
    cat > ~/.local/bin/dictate <<LAUNCHER
#!/bin/bash
VENV="$VENV_DIR"
for d in $NVIDIA_LIBS; do
    [ -d "\$d" ] && export LD_LIBRARY_PATH="\$d\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
done
exec "\$VENV/bin/python" -u "$HOME/.local/share/dictate/dictate.py" "\$@"
LAUNCHER
fi
chmod +x ~/.local/bin/dictate

# Copy the actual script and editor wrapper
cp "$SCRIPT_DIR/dictate" "$HOME/.local/share/dictate/dictate.py"
cp "$SCRIPT_DIR/dictate-editor" ~/.local/bin/dictate-editor
chmod +x ~/.local/bin/dictate-editor

# Install default config (don't overwrite existing)
mkdir -p ~/.config/dictate
if [ ! -f ~/.config/dictate/config.toml ]; then
    cp "$SCRIPT_DIR/config.toml.example" ~/.config/dictate/config.toml
    echo "Created config at ~/.config/dictate/config.toml"
fi

# Install global hints (don't overwrite existing)
mkdir -p ~/.config/dictate/hints.d
for f in "$SCRIPT_DIR"/hints.d/*; do
    [ -f "$f" ] || continue
    dst=~/.config/dictate/hints.d/"$(basename "$f")"
    [ -f "$dst" ] || cp "$f" "$dst"
done
echo "Installed global hints to ~/.config/dictate/hints.d/"

# Install Claude Code integration
mkdir -p ~/.claude/commands
cp "$SCRIPT_DIR/dictate.claude-command" ~/.claude/commands/dictate.md
echo "Installed /dictate command for Claude Code."

# Install systemd services (optional, for background daemon + push-to-talk)
if [ -d /run/systemd/system ] && [ "$ARCH" != "aarch64" ]; then
    echo ""
    read -p "Install systemd services for background daemon + push-to-talk? [Y/n] " yn
    yn="${yn:-y}"
    if [[ "$yn" =~ ^[Yy] ]]; then
        mkdir -p ~/.config/systemd/user
        cp "$SCRIPT_DIR/dictate.service" ~/.config/systemd/user/dictate.service
        cp "$SCRIPT_DIR/dictate-ptt.service" ~/.config/systemd/user/dictate-ptt.service
        systemctl --user daemon-reload
        systemctl --user enable --now dictate dictate-ptt
        echo "Services installed and started."
        if [ ! -f /usr/lib/systemd/system-sleep/dictate-resume ]; then
            echo ""
            echo "Optional: log suspend/resume events in the transcription log:"
            echo "  sudo install -m 755 $SCRIPT_DIR/dictate-resume /usr/lib/systemd/system-sleep/dictate-resume"
        fi
    fi
fi

echo ""
echo "Done! Run: dictate"
echo "  Hold Right Ctrl to record, release to transcribe."
echo "  Ctrl+V to paste the transcribed text."
echo "  Edit ~/.config/dictate/config.toml to customize."
