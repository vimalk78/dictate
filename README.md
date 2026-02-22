# dictate

Voice-to-text for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Talk to Claude instead of typing.

Uses [faster-whisper](https://github.com/SYSTRAN/faster-whisper) for local, offline speech-to-text — no cloud transcription, no API keys.

## Claude Code setup

### 1. Install

```
git clone https://github.com/vimalk78/dictate.git
cd dictate
bash install.sh
```

Reboot or re-login once (for `input` group membership).

### 2. Start the daemon

The daemon keeps the Whisper model loaded in memory for instant transcription:

```
dictate --serve &
```

### 3. Use with Claude Code

There are two ways to talk to Claude:

**Option A: `/dictate` command** — speak directly in the Claude Code prompt

```
mkdir -p ~/.claude/commands
cp dictate.claude-command ~/.claude/commands/dictate.md
```

Type `/dictate` in Claude Code, speak your prompt, pause when done. Claude hears you and responds.

**Option B: Voice editor (Ctrl+G)** — dictate into an editor, review before sending

```
EDITOR=dictate-editor claude
```

Press **Ctrl+G** to open a voice-enabled nvim editor:

| Key | Action |
|-----|--------|
| **F5** | Start recording |
| **F6** | Stop recording and transcribe |
| **F7** | Toggle spell checker |
| `:wq` | Send text to Claude |

You can press F5 multiple times to dictate in chunks — edit, spell-check, and refine before sending. Recording auto-stops after 3 seconds of silence.

## How it works

- Daemon mode with pre-loaded Whisper model — no startup delay per request
- Persistent audio stream via `sounddevice` — zero recording latency
- 1-second rolling pre-buffer — captures speech from the moment you hit the key
- Key detection via `evdev` — works globally across all windows
- Runs entirely locally — no internet, no cloud APIs, no data leaves your machine

## Standalone usage

Also works as a general-purpose push-to-talk tool outside Claude Code:

```
dictate
```

Hold **Right Ctrl** to record, release to transcribe, **Ctrl+V** to paste anywhere.

## Options

```
dictate --serve              # start daemon (keeps model loaded)
dictate --once               # send one request to daemon
dictate --stop               # stop daemon
dictate --stop-recording     # stop current recording immediately
dictate --key PAUSE          # use a different trigger key
dictate --model small        # smaller/faster model
dictate --model large-v3     # best accuracy (needs >4GB VRAM)
dictate --language hi        # Hindi, or any supported language
dictate --cpu                # force CPU inference
dictate --list-devices       # show available audio input devices
```

## Configuration

Edit `~/.config/dictate/config.toml`:

```toml
language = "en"
key = "RIGHTCTRL"
pre_buffer_secs = 1.0
silence_secs = 3.0
wait_secs = 10.0
```

## Hardware auto-detection

| Hardware | Model | Compute |
|----------|-------|---------|
| NVIDIA GPU | medium | int8 (CUDA) |
| CPU only | small | int8 |

## Requirements

- Linux with Wayland (tested on Fedora 43, should work on Ubuntu)
- Python 3.10+
- A microphone
- NVIDIA GPU (optional, falls back to CPU)

## Uninstall

```
rm -rf ~/.local/share/dictate ~/.local/bin/dictate ~/.local/bin/dictate-editor
```

## Tested on

- Fedora 43, NVIDIA GTX 1650 (4GB), Keychron K8, AirPods mic
