# Dictate — Design Document

## Overview

Voice-to-text for Claude Code on Linux. Records speech locally, transcribes using
faster-whisper (Whisper model running on GPU or CPU), outputs text via clipboard
or stdout.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    dictate                           │
│                                                     │
│  ┌─────────────┐  ┌──────────┐  ┌───────────────┐  │
│  │ Push-to-talk│  │  Daemon  │  │    Client     │  │
│  │  (default)  │  │ (--serve)│  │   (--once)    │  │
│  │             │  │          │  │               │  │
│  │ key detect  │  │ Unix sock│◄─┤ sends request │  │
│  │ + record    │  │ pre-buf  │  │ reads hints   │  │
│  │ + transcribe│  │ record   │──┤ prints text   │  │
│  │ + clipboard │  │ transcr  │  │               │  │
│  └─────────────┘  └──────────┘  └───────────────┘  │
│                                                     │
│  ┌─────────────────────────────────────────────┐    │
│  │              Shared components               │    │
│  │  sounddevice · evdev · faster-whisper        │    │
│  │  calibrate_mic · record_until_silence        │    │
│  │  load_hints · load_config · find_audio_device│    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

## Three modes of operation

### 1. Push-to-talk (default: `dictate`)

Self-contained mode. Loads model, listens for key press, records, transcribes,
copies to clipboard. No daemon needed.

- Key detection via `evdev` + `selectors.DefaultSelector` (all keyboards monitored)
- Persistent `sounddevice.InputStream` (zero startup delay)
- Transcription via `faster-whisper.WhisperModel`
- Output via `wl-copy` (Wayland clipboard)

### 2. Daemon mode (`dictate --serve`)

Keeps the Whisper model loaded in memory. Listens on a Unix domain socket for
record requests. Used for Claude Code integration where latency matters.

- Unix socket at `~/.local/share/dictate/dictate.sock`
- PID file at `~/.local/share/dictate/dictate.pid`
- Rolling 1-second pre-buffer (captures speech before request arrives)
- Calibrates mic on startup
- Handles one request at a time (sequential)
- SIGTERM/SIGINT for clean shutdown

### 3. Client mode (`dictate --once`)

Lightweight client that talks to the daemon. Records nothing — just sends a
request and prints the transcribed text.

- Connects to Unix socket
- Sends JSON: `{"language": "en", "initial_prompt": "..."}`
- Reads newline-delimited JSON responses (status updates + final text)
- Loads vocabulary hints from CWD and sends them per-request

## Protocol (daemon ↔ client)

```
Client → Daemon:  JSON request + shutdown(SHUT_WR)
Daemon → Client:  {"status": "recording"}\n
                   {"status": "transcribing"}\n
                   {"text": "transcribed text here"}\n
```

Client sends full request then half-closes the connection (SHUT_WR).
Daemon reads until EOF, processes, sends status updates and final text.

## Audio pipeline

```
mic → sounddevice.InputStream (16kHz, mono, float32)
    → callback appends to buffer
    → silence detection via RMS threshold + time.monotonic()
    → numpy concatenation → float32 array
    → faster-whisper model.transcribe()
    → text output
```

### Silence detection

- `calibrate_mic()`: measures ambient RMS for 0.5s on startup
- Threshold: `ambient * 1.5 + 0.01`, capped at 0.15
- Speech detected when any frame RMS exceeds threshold
- Recording stops after `silence_secs` (default 3s) of post-speech silence
- Timeout after `wait_secs` (default 10s) with no speech at all
- Manual stop via flag file (`~/.local/share/dictate/stop`)

### Rolling pre-buffer (daemon mode)

- Persistent `InputStream` always running with 1024-sample blocksize
- `collections.deque` with maxlen for ~1 second of audio
- When request arrives, pre-buffer snapshot is prepended to recorded audio
- Captures the first words of speech that occur before recording starts

## Audio device selection

`find_audio_device()` prefers `pipewire` ALSA device by name.
This is necessary because on PipeWire systems, the `default` ALSA device
may not route to the correct input (e.g., Bluetooth AirPods mic).
Falls back to `None` (system default) if no pipewire device found.

## Hardware auto-detection

```python
def pick_defaults():
    if has_cuda():
        return "cuda", "int8", "medium"
    else:
        return "cpu", "int8", "small"
```

- CUDA detection via `ctranslate2.get_supported_compute_types("cuda")`
- NVIDIA GPU: medium model, int8 quantization (~1GB VRAM)
- CPU only: small model, int8 (conservative for speed)
- Override with `--model`, `--cpu` flags

## Vocabulary hints

Whisper's `initial_prompt` parameter conditions the model to recognize
specific terms. Most effective for proper nouns (Claude, Anthropic, Kubernetes)
rather than code identifiers.

### Hint sources (merged, deduplicated)

1. **Global**: `~/.config/dictate/hints.d/*.hints` — ships with install
2. **Project**: `.dictate-hints.d/*.hints` in CWD — per-project

### How it works

- Client loads hints from CWD, builds prompt: `"Technical terms: Claude, Sonnet, ..."`
- Sends `initial_prompt` in request JSON to daemon
- Daemon passes it to `model.transcribe(initial_prompt=...)`
- Per-request — no daemon restart when switching projects

### Limitations

- Works well for proper nouns (Claude vs cloud, Haiku vs haiku)
- Does NOT help with code identifiers (function names, variables)
- `hotwords` parameter was tested and removed — too aggressive with many terms

## Configuration

`~/.config/dictate/config.toml`:

```toml
language = "en"          # transcription language
key = "RIGHTCTRL"        # trigger key for push-to-talk
pre_buffer_secs = 1.0    # rolling pre-buffer duration
silence_secs = 3.0       # silence duration to stop recording
wait_secs = 10.0         # timeout with no speech
```

## Claude Code integration

### /dictate command

Custom slash command that loops `dictate --once`, accumulating text
until the user goes silent. Installed to `~/.claude/commands/dictate.md`.

### dictate-editor (Ctrl+G)

Wrapper script that opens nvim with injected Lua keybindings:

| Key | Action |
|-----|--------|
| F5  | Start recording (async via `vim.fn.jobstart`) |
| F6  | Stop recording (`dictate --stop-recording`) |
| F7  | Toggle spell checker |
| :wq | Send text to Claude |

- Uses `vim.fn.jobstart()` for async recording (nvim stays responsive)
- `vim.defer_fn(..., 50)` for reliable status messages after mode changes
- Shows word count instead of full text to avoid "Press ENTER" overflow

Launch: `EDITOR=dictate-editor claude`

## File layout

```
~/.local/bin/dictate              # launcher (sets VENV, LD_LIBRARY_PATH)
~/.local/bin/dictate-editor       # nvim wrapper for Ctrl+G
~/.local/share/dictate/
    venv/                         # Python venv with dependencies
    dictate.py                    # main script
    dictate.sock                  # Unix socket (daemon)
    dictate.pid                   # PID file (daemon)
    stop                          # flag file for --stop-recording
~/.config/dictate/
    config.toml                   # user configuration
    hints.d/
        claude.hints              # global vocabulary hints
~/.claude/commands/
    dictate.md                    # /dictate slash command
```

## Dependencies

### System packages
- `portaudio` — audio I/O
- `wl-clipboard` — Wayland clipboard (`wl-copy`)

### Python packages (in venv)
- `faster-whisper` — Whisper inference via ctranslate2
- `evdev` — Linux input device access
- `sounddevice` — PortAudio bindings
- `numpy` — audio buffer manipulation
- `nvidia-cublas-cu12` — CUDA libs (only if NVIDIA GPU present)

## Known issues and decisions

- **Wayland**: `wtype` doesn't work on GNOME Wayland ("compositor does not support
  virtual keyboard protocol"), so clipboard via `wl-copy` is used instead
- **AirPods mic**: Must use `pipewire` ALSA device, not `default`, to pick up
  Bluetooth audio
- **CUDA 13 + ctranslate2**: Needs `nvidia-cublas-cu12` pip package because
  ctranslate2 links against libcublas.so.12
- **Threshold cap at 0.15**: Prevents false "no speech" from noisy calibration
  (e.g., AirPods connecting during startup)
- **`hotwords` removed**: Tested but degraded transcription quality with many terms
