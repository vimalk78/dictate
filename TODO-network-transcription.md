# Network Transcription Server

## Goal

Separate recording and transcription so a GPU machine on the LAN can serve
transcription requests from any device. Thin clients just need a mic.

## Architecture

```
[client: laptop/desktop]              [server: GPU machine]
 mic → record audio  ────TCP────→  receive audio → transcribe → send text back
```

## Current state

- Daemon uses Unix socket (`dictate.sock`) for local IPC
- Protocol is JSON over socket (newline-delimited)
- Client sends: `{"language": "en", "initial_prompt": "..."}`
- Server sends: `{"status": "recording"}`, `{"status": "transcribing"}`, `{"text": "..."}`
- Recording and transcription both happen on the daemon side

## Proposed changes

### Server side (`dictate --serve --listen 0.0.0.0:5555`)

- Add `--listen HOST:PORT` flag — enables TCP mode instead of Unix socket
- Server does NOT record — it only transcribes
- Receives raw audio bytes (16kHz, mono, float32) from client
- Protocol:
  1. Client sends JSON header (length-prefixed): `{"language": "en", "initial_prompt": "...", "audio_length": 156800}`
  2. Client sends raw audio bytes
  3. Server transcribes and responds: `{"text": "..."}`
- Keep Unix socket mode as default for local use (no breaking changes)

### Client side (`dictate --once --server 192.168.x.x:5555`)

- Add `--server HOST:PORT` flag — sends audio to remote server
- Client handles all recording locally (mic, silence detection, pre-buffer)
- After recording, sends audio over TCP to the server
- Receives transcription text back
- Falls back to local daemon if `--server` not specified

### Config

```toml
# ~/.config/dictate/config.toml
server = "192.168.1.100:5555"   # remote transcription server
```

## Audio data size

- 16kHz, mono, float32 = 64KB/s
- 10 second recording = 640KB
- Trivial on LAN, fine even on WiFi

## Security considerations

- Audio sent in plaintext — acceptable for home LAN
- Optional: add a shared secret/token for basic auth
- Do NOT expose to internet without TLS

## What stays the same

- Push-to-talk mode (local only, unchanged)
- Unix socket daemon mode (local only, unchanged)
- dictate-editor, /dictate command (unchanged, just points to --server)
- Vocabulary hints (client sends initial_prompt as before)
- All recording logic stays on client side

## Implementation steps

1. Refactor `serve()` to accept audio bytes instead of recording
2. Add TCP listener option to `serve()`
3. Add `--server` flag to client
4. Client records locally, sends audio bytes over TCP
5. Add `server` to config.toml
6. Test on LAN between two machines
7. Update README
