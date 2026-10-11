# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this

Dictate is a voice-to-text tool for Claude Code on Linux. It records speech using faster-whisper and outputs text via clipboard or stdout. Supports local transcription or forwarding audio to a remote GPU server over TCP. Single Python script (`dictate`), no build system.

## Development

### Running locally

```bash
bash install.sh                    # checks requirements (prints fix commands, never sudo), then venv + launcher; also the upgrade path (detects an existing install, asks, restarts running services)
bash uninstall.sh                  # remove everything (asks before config/models; --purge to skip)
bash install-service.sh            # install and start systemd services
bash update.sh                     # update after code changes (no venv rebuild; refuses if requirements.lock changed)
dictate --serve &                  # start daemon (keeps Whisper model in memory)
dictate --once                     # send one request to daemon, print text
dictate                            # standalone push-to-talk mode (no daemon)

# Network transcription (remote GPU)
dictate --serve --listen 0.0.0.0:5555   # on GPU machine: headless transcription server
dictate --serve --server GPU_IP:5555    # on laptop: daemon forwarding to remote
dictate --once                          # client unchanged
```

After install, reboot or re-login once for `input` group membership (required for evdev access).

After code changes, run `bash update.sh` to deploy — it copies the script, service files, and restarts running services. No venv rebuild needed. If `requirements.lock` changed since the last install (compared with the copy in `~/.local/share/dictate/`), it refuses and asks for `install.sh` instead.

### Testing

Install test (fresh distro in a podman container — run before each release):

```bash
bash tests/install-test.sh fedora:44     # also: ubuntu:24.04, ubuntu:22.04 (Python 3.10, like Jetson)
```

It runs install.sh on a bare image (must fail with a requirements list), applies the printed fixes, installs, transcribes a speech sample via `--listen`, then checks `uninstall.sh --purge` leaves nothing. It cannot test mic, keyboard, clipboard, or services.

No unit tests. Manual testing:

```bash
dictate --serve &                  # start daemon
dictate --once                     # test transcription
dictate --cpu --model small        # test CPU-only inference
dictate --list-devices             # verify audio device detection
dictate --stop                     # stop daemon

# Network transcription
dictate --serve --listen 0.0.0.0:5555   # start remote server
dictate --serve --server 127.0.0.1:5555 # start forwarding daemon
dictate --once                          # test end-to-end
```

Test local daemon, network forwarding, and push-to-talk separately — they share audio and transcription code but have different I/O paths.

## Architecture

Single Python script (`dictate`, ~1180 lines) with six modes:

1. **Push-to-talk** (default) — loads model, listens for key press via evdev, records, transcribes, copies to clipboard via `xsel`
2. **Daemon** (`--serve`) — keeps model loaded, listens on Unix socket (`~/.local/share/dictate/dictate.sock`), maintains rolling 1-second pre-buffer, handles one request at a time
3. **Daemon forwarding** (`--serve --server H:P`) — same as daemon but skips model loading; after recording, forwards audio over TCP to a remote transcription server
4. **TCP transcription server** (`--serve --listen H:P`) — headless, no mic; receives audio over TCP, transcribes with local Whisper model, returns text
5. **Client** (`--once`) — connects to daemon socket, sends JSON request with language + hints, reads newline-delimited JSON responses, prints final text to stdout (unchanged by network mode)
6. **PTT client** (`--ptt`) — no model, no mic; watches the key via evdev, sends a `--once`-style request to the daemon, touches `STOP_FLAG` on key release, copies the result with `xsel`. Runs as `dictate-ptt.service`

### Daemon ↔ Client protocol (Unix socket)

```
Client → Daemon:  {"language": "en", "initial_prompt": "..."} + shutdown(SHUT_WR)
Daemon → Client:  {"status": "recording"}\n
                   {"status": "transcribing"}\n
                   {"text": "transcribed text here"}\n
```

### Daemon ↔ TCP server protocol (network transcription)

```
Daemon → Server:
  4 bytes:  header length (uint32 big-endian)
  N bytes:  JSON header {"language": "en", "initial_prompt": "...", "audio_length": M}
  M bytes:  raw float32 audio (16kHz mono)

Server → Daemon:
  {"text": "transcribed text here"}\n
```

### Audio pipeline

`sounddevice.InputStream` (16kHz mono float32) → RMS-based silence detection → numpy array → `faster-whisper model.transcribe()`. Silence threshold is calibrated from 0.5s ambient measurement on startup: `ambient * 1.5 + 0.01`, capped at 0.05. Calibration retries on silence (rms=0) or suspiciously high ambient (>0.03, e.g. device switching). A background mic monitor thread detects disconnects and re-calibrates on reconnect, sending desktop notifications via `notify-send`.

### Key functions

- `calibrate_mic()` — ambient RMS measurement with retry logic, sets speech threshold
- `record_until_silence()` — records until post-speech silence or timeout, respects STOP_FLAG
- `transcribe_audio()` — local transcription via faster-whisper model
- `transcribe_remote()` — forwards audio to TCP server, returns text
- `serve()` — daemon loop: socket listener + pre-buffer, transcribes locally or forwards to remote
- `serve_tcp()` — headless TCP transcription server (for GPU machine)
- `client_once()` — client: connect, send request, read JSON stream
- `push_to_talk()` — standalone: evdev key detection + record + transcribe + clipboard
- `load_hints()` — merges global (`~/.config/dictate/hints.d/`) and project (`.dictate-hints.d/`) hint files
- `find_audio_device()` — prefers pipewire ALSA device for correct Bluetooth routing
- `load_model()` — loads the Whisper model from the local cache; network only if not downloaded yet
- `pick_defaults()` — CUDA auto-detection: GPU → medium/int8, CPU → small/int8
- `parse_addr()` — parses HOST:PORT strings for network modes

### Claude Code integration

- `/dictate` command (`dictate.claude-command`) — loops `dictate --once`, accumulates utterances
- `/dictate-hints` command (`dictate-hints.claude-command`) — auto-generates project vocabulary hints
- `dictate-editor` — nvim wrapper with F5/F6/F7 voice keybindings, used as `EDITOR=dictate-editor claude`

## Key design decisions

- **Clipboard via `xsel` (XWayland)**: `wtype` doesn't work on GNOME Wayland, and `wl-copy` can't set the selection without focus; `xsel` has no focus requirement (see BUGS.md)
- **Pinned dependencies**: `requirements.txt` lists direct deps; `requirements.lock` (generated with `uv pip compile requirements.txt --universal --python-version 3.10 -o requirements.lock`) pins exact versions, with separate entries for Python 3.10. install.sh installs the lock. Regenerating with the old lock in place keeps existing pins where possible
- **Installer never uses sudo**: install.sh checks everything first and prints the commands to run; `uv` is required (single install path)
- **PipeWire preference**: `default` ALSA device doesn't route Bluetooth mic correctly; must use pipewire device by name
- **`hotwords` removed**: tested but degraded transcription with many terms; `initial_prompt` works better
- **`hallucination_silence_threshold=2`**: prevents Whisper from hallucinating text on silence
- **Threshold cap 0.05**: prevents false "no speech" from noisy calibration (e.g., AirPods connecting/disconnecting)
- **Calibration retry on noise**: ambient RMS > 0.03 triggers retry — catches PipeWire route switching transients
- **Mic health monitor**: background thread checks pre-buffer RMS every 5s, sends `notify-send` on disconnect, re-calibrates on reconnect
- **Hints are per-request**: sent in client JSON, no daemon restart when switching projects
- **Network transcription**: local daemon records and forwards raw audio over TCP; remote server is stateless and handles transcription only. `--once` client is completely unaware of network mode

## Jetson Orin Nano (aarch64)

JetPack 6.x ships Python 3.10 and no PyPI ctranslate2 CUDA wheels for aarch64. Two extra steps:

1. **Build ctranslate2 from source** (once, before `install.sh`):
   ```bash
   bash build-ctranslate2.sh
   ```
   This saves a wheel to `~/.local/share/dictate/wheels/`.
2. **Run install.sh** — detects aarch64, installs the pre-built wheel together with the lock minus its `ctranslate2` pin (otherwise uv would swap in PyPI's CPU-only wheel), skips `nvidia-cublas-cu12` (CUDA libs from JetPack), uses `/usr/local/cuda/lib64` in launcher.

The `tomli` backport is installed automatically for Python < 3.11.

## Installed file locations

```
~/.local/bin/dictate              # launcher (sets VENV, LD_LIBRARY_PATH)
~/.local/bin/dictate-editor       # nvim wrapper
~/.local/share/dictate/venv/      # Python venv
~/.local/share/dictate/dictate.py # main script (copied from repo)
~/.local/share/dictate/version    # installed `git describe` (shown on reinstall)
~/.local/share/dictate/requirements.lock  # lock used for the venv (checked by update.sh)
~/.config/dictate/config.toml     # user config
~/.config/dictate/hints.d/        # global vocabulary hints
```
