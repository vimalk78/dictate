# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this

Dictate is a voice-to-text tool for Claude Code on Linux. It records speech locally using faster-whisper (offline, no cloud APIs) and outputs text via clipboard or stdout. Single Python script (`dictate`), no build system.

## Development

### Running locally

```bash
bash install.sh                    # full install (system deps, venv, launcher)
dictate --serve &                  # start daemon (keeps Whisper model in memory)
dictate --once                     # send one request to daemon, print text
dictate                            # standalone push-to-talk mode (no daemon)
```

After install, reboot or re-login once for `input` group membership (required for evdev access).

### Testing

No test suite. Manual testing:

```bash
dictate --serve &                  # start daemon
dictate --once                     # test transcription
dictate --cpu --model small        # test CPU-only inference
dictate --list-devices             # verify audio device detection
dictate --stop                     # stop daemon
```

Test both daemon mode (`--serve` / `--once`) and standalone push-to-talk mode separately — they share audio and transcription code but have different I/O paths.

## Architecture

Single Python script (`dictate`, ~565 lines) with three modes:

1. **Push-to-talk** (default) — loads model, listens for key press via evdev, records, transcribes, copies to clipboard via `wl-copy`
2. **Daemon** (`--serve`) — keeps model loaded, listens on Unix socket (`~/.local/share/dictate/dictate.sock`), maintains rolling 1-second pre-buffer, handles one request at a time
3. **Client** (`--once`) — connects to daemon socket, sends JSON request with language + hints, reads newline-delimited JSON responses, prints final text to stdout

### Daemon ↔ Client protocol

```
Client → Daemon:  {"language": "en", "initial_prompt": "..."} + shutdown(SHUT_WR)
Daemon → Client:  {"status": "recording"}\n
                   {"status": "transcribing"}\n
                   {"text": "transcribed text here"}\n
```

### Audio pipeline

`sounddevice.InputStream` (16kHz mono float32) → RMS-based silence detection → numpy array → `faster-whisper model.transcribe()`. Silence threshold is calibrated from 0.5s ambient measurement on startup: `ambient * 1.5 + 0.01`, capped at 0.15.

### Key functions

- `calibrate_mic()` — ambient RMS measurement, sets speech threshold
- `record_until_silence()` — records until post-speech silence or timeout, respects STOP_FLAG
- `serve()` — daemon loop: socket listener + persistent audio stream with pre-buffer
- `client_once()` — client: connect, send request, read JSON stream
- `push_to_talk()` — standalone: evdev key detection + record + transcribe + clipboard
- `load_hints()` — merges global (`~/.config/dictate/hints.d/`) and project (`.dictate-hints.d/`) hint files
- `find_audio_device()` — prefers pipewire ALSA device for correct Bluetooth routing
- `pick_defaults()` — CUDA auto-detection: GPU → medium/int8, CPU → small/int8

### Claude Code integration

- `/dictate` command (`dictate.claude-command`) — loops `dictate --once`, accumulates utterances
- `/dictate-hints` command (`dictate-hints.claude-command`) — auto-generates project vocabulary hints
- `dictate-editor` — nvim wrapper with F5/F6/F7 voice keybindings, used as `EDITOR=dictate-editor claude`

## Key design decisions

- **Wayland only**: `wtype` doesn't work on GNOME Wayland, so clipboard via `wl-copy` is used
- **PipeWire preference**: `default` ALSA device doesn't route Bluetooth mic correctly; must use pipewire device by name
- **`hotwords` removed**: tested but degraded transcription with many terms; `initial_prompt` works better
- **`hallucination_silence_threshold=2`**: prevents Whisper from hallucinating text on silence
- **Threshold cap 0.15**: prevents false "no speech" from noisy calibration (e.g., AirPods connecting)
- **Hints are per-request**: sent in client JSON, no daemon restart when switching projects

## Installed file locations

```
~/.local/bin/dictate              # launcher (sets VENV, LD_LIBRARY_PATH)
~/.local/bin/dictate-editor       # nvim wrapper
~/.local/share/dictate/venv/      # Python venv
~/.local/share/dictate/dictate.py # main script (copied from repo)
~/.config/dictate/config.toml     # user config
~/.config/dictate/hints.d/        # global vocabulary hints
```
