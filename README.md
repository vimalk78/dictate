# dictate

Voice-to-text anywhere on your Linux desktop. Press a key, speak, release, paste.

Uses [faster-whisper](https://github.com/SYSTRAN/faster-whisper) for local, offline speech-to-text — no cloud transcription, no API keys. Whisper handles capitalization and punctuation automatically.

### Demo

https://github.com/user-attachments/assets/1721056f-6b26-47af-86c0-0f936ce5eb9f

## Quick start

```
git clone https://github.com/vimalk78/dictate.git
cd dictate
bash install.sh
bash install-service.sh
```

Reboot or re-login once (for `input` group membership). That's it.

Two background services start on every login:
- **dictate** — daemon with Whisper model loaded in memory
- **dictate-ptt** — push-to-talk listener (system-wide keyboard detection)

**The flow:** press **Right Ctrl** in any window, speak, release the key. A bell rings when transcription is done. Press **Ctrl+V** to paste. Works in your terminal, browser, editor, Claude Code — anywhere.

No GPU required. On NVIDIA GPUs it uses the `medium` model for higher accuracy. On CPU (including Intel integrated) it uses the `small` model — still quite good for English. Works with your laptop mic, external mic, or AirPods.

## Claude Code integration

The system-wide push-to-talk works directly with Claude Code — press Right Ctrl, speak your prompt, release, hear the bell, Ctrl+V into the Claude Code input. No special setup needed.

<details>
<summary>Optional: voice-enabled editor and /dictate command</summary>

**Voice editor (Ctrl+G)** — for longer prompts you want to review before sending:

```
EDITOR=dictate-editor claude
```

Press Ctrl+G to open nvim with voice keybindings (F5 record, F6 stop/transcribe, F7 spell check). Dictate in chunks, edit, then `:wq` to send.

**/dictate command** — speak directly into the Claude Code prompt:

```
mkdir -p ~/.claude/commands
cp dictate.claude-command ~/.claude/commands/dictate.md
```

Type `/dictate`, speak, pause when done.
</details>

## Network transcription

Don't have a GPU on your laptop? Run the Whisper model on a GPU machine on your LAN and forward audio to it over TCP. The push-to-talk client doesn't know or care — it works exactly the same.

On the GPU machine (headless, no mic needed):

```
dictate --serve --listen 0.0.0.0:5555
```

On your laptop:

```
dictate --serve --server GPU_IP:5555
bash install-service.sh
```

Or set the server permanently in `~/.config/dictate/config.toml`:

```toml
server = "192.168.1.100:5555"
```

Audio is sent as raw float32 over TCP (~64KB/s) — trivial on a LAN.

## How it works

- **Two background services** — daemon (model loaded) + push-to-talk (keyboard listener). No terminal needed.
- **System-wide key detection** via `evdev` — works in any window, any app. Detects keyboard disconnect/reconnect automatically (e.g. KVM switches).
- **Sound notifications** — bell rings when transcription is done, so you know when to paste.
- **Pre-loaded Whisper model** — no startup delay per request. The model stays in memory.
- **1-second rolling pre-buffer** — captures speech from the moment you press the key.
- **Runs entirely locally** — no internet, no cloud APIs, no data leaves your machine.

## Options

```
dictate --serve              # start daemon (keeps model loaded)
dictate --ptt                # push-to-talk via daemon (system-wide, sound notifications)
dictate --once               # send one request to daemon, print text
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
| CPU only (Intel, AMD) | small | int8 |

No GPU required. The `small` model on CPU is good enough for English dictation. NVIDIA GPU gives you the `medium` model for better accuracy, especially with technical terms and non-English languages.

## Requirements

- Linux with Wayland (tested on Fedora 43, Ubuntu 22.04)
- Python 3.10+
- A microphone (laptop mic, USB mic, AirPods — anything that shows up as an input device)
- NVIDIA GPU (optional, falls back to CPU)
- For Jetson (aarch64): build ctranslate2 from source first — see `build-ctranslate2.sh`

## Uninstall

```
bash uninstall-service.sh    # remove systemd services (if installed)
rm -rf ~/.local/share/dictate ~/.local/bin/dictate ~/.local/bin/dictate-editor
```

## Tested on

- Fedora 43, NVIDIA GTX 1650 (4GB), Keychron K8, AirPods mic
- Fedora 43, Intel integrated (no GPU), laptop mic + AirPods
- Jetson Orin Nano (JetPack 6.x, 8GB), network transcription server
