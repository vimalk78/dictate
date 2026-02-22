# dictate

Push-to-talk voice-to-text for Linux using [faster-whisper](https://github.com/SYSTRAN/faster-whisper).

Hold a key, speak, release — transcribed text is copied to clipboard.

## How it works

- Persistent audio stream via `sounddevice` (zero startup delay)
- Key press/release detection via `evdev` (works globally, any window)
- Transcription via `faster-whisper` (runs locally, offline, no cloud)
- Output via `wl-copy` (Wayland clipboard)

## Requirements

- Linux with Wayland (tested on Fedora 43, should work on Ubuntu)
- Python 3.10+
- A microphone
- NVIDIA GPU (optional, falls back to CPU)

## Install

```
git clone https://github.com/vimalk78/dictate.git
cd dictate
bash install.sh
```

Reboot or re-login once (for `input` group membership).

## Daemon mode

Keep the model loaded in memory for instant transcription:

```
dictate --serve &
```

Then use the lightweight client anywhere:

```
dictate --once
```

Stop the daemon:

```
dictate --stop
```

## Claude Code integration

### /dictate command

Copy the custom command to your Claude Code config:

```
mkdir -p ~/.claude/commands
cp dictate.claude-command ~/.claude/commands/dictate.md
```

Start the daemon, then use `/dictate` in Claude Code to speak your prompt.

### Voice-to-editor (Ctrl+G)

Launch Claude Code with the voice editor:

```
EDITOR=dictate-editor claude
```

Press **Ctrl+G** — it records your voice, opens the transcription in nvim for editing, and sends the final text to Claude when you save and quit.

## Uninstall

```
rm -rf ~/.local/share/dictate ~/.local/bin/dictate ~/.local/bin/dictate-editor
```

## Usage

```
dictate
```

- Hold **Right Ctrl** to record
- Release to transcribe
- **Ctrl+V** to paste

## Options

```
dictate --key PAUSE          # use a different trigger key
dictate --model small        # smaller/faster model
dictate --model large-v3     # best accuracy (needs >4GB VRAM)
dictate --language hi         # Hindi, or any supported language
dictate --cpu                 # force CPU inference
dictate --list-devices        # show available input devices
dictate --device /dev/input/event6  # use specific keyboard device
```

## Hardware auto-detection

| Hardware | Model | Compute |
|----------|-------|---------|
| NVIDIA GPU | medium | int8 (CUDA) |
| CPU only | small | int8 |

## Tested on

- Fedora 43, NVIDIA GTX 1650 (4GB), Keychron K8, AirPods mic
