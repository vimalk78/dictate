# dictate

Voice-to-text for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) on Linux. Talk to Claude instead of typing.

Uses [faster-whisper](https://github.com/SYSTRAN/faster-whisper) for local, offline speech-to-text on Linux/Wayland — no cloud transcription, no API keys.

### Demo

https://github.com/user-attachments/assets/09645745-e30d-4945-859f-b8932bbda8c4

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

## Network transcription

Offload transcription to a GPU machine on your LAN. The local daemon records audio and forwards it over TCP — the client (`--once`) is completely unaware of network mode.

On the GPU machine (headless, no mic needed):

```
dictate --serve --listen 0.0.0.0:5555
```

On your laptop:

```
dictate --serve --server GPU_IP:5555
dictate --once    # works exactly the same as local mode
```

Or set it permanently in `~/.config/dictate/config.toml`:

```toml
server = "192.168.1.100:5555"
```

Audio is sent as raw float32 over TCP (~64KB/s) — trivial on a LAN.

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
dictate --serve --listen 0.0.0.0:5555  # headless TCP transcription server
dictate --serve --server IP:5555       # daemon forwarding to remote GPU
```

## Configuration

Edit `~/.config/dictate/config.toml`:

```toml
language = "en"
key = "RIGHTCTRL"
pre_buffer_secs = 1.0
silence_secs = 3.0
wait_secs = 10.0
server = ""              # "HOST:PORT" for network transcription
```

## Vocabulary hints

Whisper can struggle with technical terms — "Claude" becomes "cloud", "Kubernetes" becomes "kubernetes". Hints fix this.

Hints are loaded from two directories, merged together:

| Directory | Scope | Ships with |
|-----------|-------|------------|
| `~/.config/dictate/hints.d/` | Global (always loaded) | `install.sh` |
| `.dictate-hints.d/` in CWD | Project-specific | You or `/dictate-hints` |

Each file contains one term per line (`#` comments supported). All files in both directories are merged and deduplicated.

**Global hints** are installed automatically — includes common Claude, dev tooling, and language terms.

**Project hints** — create `.dictate-hints.d/` in your project root and drop files in:

```
.dictate-hints.d/
  project.hints     # MyClassName, my_function, ProjectName
  infra.hints       # Terraform, Ansible, Helm
```

Or use `/dictate-hints` in Claude Code to auto-generate from your codebase:

```
cp dictate-hints.claude-command ~/.claude/commands/dictate-hints.md
```

Hints are sent per-request — no daemon restart needed when switching projects.

## Hardware auto-detection

| Hardware | Model | Compute |
|----------|-------|---------|
| NVIDIA GPU | medium | int8 (CUDA) |
| CPU only | small | int8 |

## Requirements

- Linux with Wayland (tested on Fedora 43, Ubuntu 22.04)
- Python 3.10+
- A microphone (not needed on headless transcription server)
- NVIDIA GPU (optional, falls back to CPU)
- For Jetson (aarch64): build ctranslate2 from source first — see `build-ctranslate2.sh`

## Uninstall

```
rm -rf ~/.local/share/dictate ~/.local/bin/dictate ~/.local/bin/dictate-editor
```

## Tested on

- Fedora 43, NVIDIA GTX 1650 (4GB), Keychron K8, AirPods mic
- Jetson Orin Nano (JetPack 6.x, 8GB), network transcription server
