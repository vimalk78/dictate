# Two-service redesign: `dictate` + `dictate-server`

**Status: DRAFT — brainstorming in progress (paused 2026-10-05).**
Direction and decisions below are agreed. The Phase 1 design is a
*proposal* that has not yet been reviewed section by section. No
implementation plan exists yet; no code has been written.

**To resume:** review the Phase 1 proposal (§5) section by section,
resolve the open questions (§8), finalize this spec, then write the
implementation plan (writing-plans).

---

## 1. Goal

Split transcription out of the desktop daemon into its own service, so the
same architecture serves local (CPU) and LAN (GPU) transcription, and a
desktop automatically uses the GPU machine on its LAN when it's reachable,
falling back to local CPU otherwise — with no IP addresses to configure.

**Success:** at either location, press Right Ctrl and speak; it transcribes
on the LAN's GPU machine if it's up, otherwise on the local CPU. No config
edits when moving between locations. Switching on the GPU machine after
the laptop picks it up automatically.

## 2. Environment (single user)

| Device | Location | Mic side | Transcription side |
|---|---|---|---|
| Jetson Orin Nano (`vimal-jetson`) | Patiala | — (headless, no desktop) | GPU |
| Mini PC (`azad`, Fedora 44, i5-6600T) | Patiala | yes (test bed) | local CPU fallback |
| PDP-11 (Fedora, GTX 1650 4GB) | Bangalore | yes (needs a mic) | GPU, also used by itself |
| Laptop (Fedora, i7, primary daily machine) | moves Patiala ↔ Bangalore, ~once a year | yes | local CPU fallback |

- Push-to-talk (Right Ctrl) is ~100% of usage. `/dictate` and
  `dictate-editor` are rarely used; keep them working only where cheap.
- Same keyboard/mouse/mic are switched between machines (KVM-style).
  Mics vary: USB webcam mic, AirPods, Bose.
- All machines run Avahi (mDNS) by default: `<hostname>.local` resolves on
  the LAN with no configuration (verified: `vimal-jetson.local` →
  192.168.1.36 from the mini PC, no `/etc/hosts` entry).

## 3. Decisions (agreed)

1. **LAN only.** No cross-location connections, no Tailscale, no internet.
2. **No service discovery.** Config names the GPU machine(s) by `.local`
   hostname. A `.local` name only resolves on the LAN where that machine is,
   so listing both (`vimal-jetson.local`, `pdp-11.local`) means no edits
   when travelling. (A single name edited once a year is also acceptable.)
3. **Selection:** use the configured GPU server if reachable, else the
   local CPU server. Config can disable the local fallback.
4. **When to check reachability:** after each transcription (off the key
   press path), and on failure.
5. **On failure mid-request:** the recorded audio is retried on the local
   server — never lost.
6. **Local CPU server is always running** (model always loaded). User has
   run CPU transcription always-loaded with no noticeable cost.
7. **Two phases**, each independently testable and releasable:
   - **Phase 1:** transcription split. `dictate-ptt` and `STOP_FLAG`
     unchanged.
   - **Phase 2:** merge PTT + mic into one process; remove `STOP_FLAG`.
8. **Rollout:** develop on a branch; run on mini PC + Jetson (Patiala)
   until stable; the laptop stays on v0.1.0 until then. Rollback =
   `uninstall.sh`, checkout `v0.1.0`, `install.sh`.
9. **Out of scope:** Parakeet (separate spike: prove it runs on the Jetson,
   then bring it behind the same protocol); auto-discovery (mDNS/DNS-SD
   service announcement); multi-user/auth beyond the LAN.

## 4. Today's architecture (v0.1.0)

One script, `dictate`, run in modes by flags:

- `dictate-ptt.service` → `dictate --ptt`: watches the key (evdev), sends a
  request over the Unix socket on key-down, touches `STOP_FLAG` on key-up,
  copies text with `xsel`, plays a sound. No mic, no model.
- `dictate.service` → `dictate --serve`: the daemon. **Mic + model in one
  process**: rolling pre-buffer, records, transcribes. Unix socket
  `~/.local/share/dictate/dictate.sock`. With `server = "IP:5555"` in config
  it skips the model and forwards audio — either/or, no fallback.
- `dictate-server.service` → `dictate --serve --listen 0.0.0.0:5555`: TCP
  transcription server, model only. Not installed by `install.sh` (set up
  by hand on the Jetson).

Why PTT is a separate process (commit `73abe11`): to share the daemon's
model instead of loading a second one — not for device monitoring.

Why `STOP_FLAG` exists (commit `74411f0`): `dictate-editor`'s F6 must stop a
recording started by another process; the daemon handles one connection at
a time and is busy in its recording loop, so a polled file was the simplest
out-of-band signal. PTT reused it. No scenario was found where a file is
inherently required; it is a workaround for the single-threaded daemon, and
caused races #19 and #22 (see BUGS.md, `tlaplus/`).

## 5. Phase 1 proposal (NOT YET REVIEWED)

### 5.1 Components

- **`dictate-server`** (today's `serve_tcp`): loads the model, transcribes
  audio sent over TCP. No mic, no keyboard, no state between requests.
  Same program everywhere; model/device differ per machine.
- **Desktop daemon** (`dictate --serve`): mic + recording as today, but
  **never loads a model**; always sends audio to a `dictate-server`.
- **`dictate-ptt`**: unchanged.

| Machine | `dictate-server` | Listens on | Desktop daemon uses |
|---|---|---|---|
| Jetson | GPU | `0.0.0.0:5555` | — |
| PDP-11 | GPU | `0.0.0.0:5555` | `127.0.0.1:5555` (itself), no CPU fallback |
| Mini PC, laptop | CPU | `127.0.0.1:5556` | `vimal-jetson.local:5555` / `pdp-11.local:5555`, then `127.0.0.1:5556` |

### 5.2 Protocol (backward compatible with v0.1.0 clients)

Existing request: 4-byte length + JSON header + float32 PCM. Additions:

- **Health check:** header `{"type": "ping"}`, no audio → reply
  `{"ok": true, "model": "...", "device": "cuda|cpu"}\n`. A header without
  `"type"` is a transcription request, as today.
- **Errors:** always `{"error": "..."}\n`; clients must read and surface
  them (today's client ignores them — open bug #1).
- **Limits:** reject `audio_length` above a cap (e.g. 10 min of audio).

### 5.3 Backend selection and failure handling

- Candidates, in order: configured GPU server(s), then the local server
  (if `local_fallback`).
- A background check pings candidates in order (short connect timeout,
  ~0.5s) at startup and after each transcription; the first healthy one
  becomes current.
- Request path: send to current. On connect error, timeout, or error
  reply: mark it down, retry the **same audio** on the next healthy
  candidate (normally local). Timeouts: connect ~1s; transcription
  proportional to audio length (e.g. `max(30s, 3 × duration)`).
- Desktop notification when the backend changes (e.g. "Using Jetson GPU" /
  "Jetson unavailable — using local CPU").

### 5.4 Config (`~/.config/dictate/config.toml`)

```toml
servers = ["vimal-jetson.local", "pdp-11.local"]   # GPU servers, in preference order (port 5555 default)
local_fallback = true                               # use the local dictate-server if no GPU server answers
local_server = "127.0.0.1:5556"
```

The existing single `server = "H:P"` stays accepted.

### 5.5 Services and install

- Desktops: `dictate.service` (daemon, no model), `dictate-ptt.service`
  (unchanged), `dictate-server.service` (local CPU, `127.0.0.1:5556`,
  `MemoryMax`). The daemon no longer needs a model, so a missing mic no
  longer reloads one (fixes the PDP-11 crash loop, bug #3 in the open list).
- Jetson: `dictate-server.service` only (`0.0.0.0:5555`). Today
  `install.sh` installs no services on aarch64 — needs a server-only path.
- PDP-11: GPU `dictate-server` on `0.0.0.0:5555`; desktop daemon points at
  `127.0.0.1:5555` with `local_fallback = false`.

### 5.6 Testing

- Container test (`tests/install-test.sh`): extend for the server-only
  install and for daemon → local server transcription.
- Hardware, on mini PC + Jetson: Jetson off at start / switched on later /
  killed mid-request; server hang (accepts, never replies); suspend/resume;
  mic switching (webcam, AirPods, Bose); KVM switching.
- Verify `pdp-11.local` resolves on the Bangalore LAN (Avahi running on
  PDP-11) before relying on it there.

## 6. Phase 2 outline (separate design later)

- Merge `dictate-ptt` and the desktop daemon into one `dictate` process:
  keyboard watcher and mic watcher as threads; key release becomes an
  in-process event; `STOP_FLAG` removed.
- `--stop-recording` (editor F6): becomes a socket command, which requires
  the socket handling to run in its own thread so it can accept a "stop"
  while recording. Alternative: keep the file for this rare path only.
- Recalibrate immediately when the default input changes (PipeWire
  announces it, `pactl subscribe`), not only after 30s of silence.
- Mic recovery should recalibrate from the existing stream instead of
  opening a second one (open bug #7).

## 7. Related open bugs (from the v0.1.0 review)

| # | Bug | Phase 1? |
|---|---|---|
| 1 | Errors swallowed (no newline at `dictate:785`; client ignores `"error"`) | yes — protocol |
| 2 | No timeout in `transcribe_remote()` | yes — selection/timeouts |
| 3 | Model loaded before mic check; no restart backoff | mostly (daemon has no model); backoff still needed |
| 4 | PTT silent while the daemon starts | not covered — small separate fix |
| 5 | Bug #16 Whisper params silently reverted | no — measure in the Parakeet/benchmark spike |
| 6 | TCP server binds 0.0.0.0, trusts `audio_length` | partly — size cap; LAN-only, no auth |
| 7 | Mic recovery opens a second stream | phase 2 |

## 8. Open questions

1. Names: proposed `dictate` (desktop side) + `dictate-server`
   (transcription). Not yet confirmed.
2. Port numbers (5555 GPU, 5556 local) — or one port everywhere?
3. `install.sh` roles: how to choose desktop / server-only (Jetson) /
   both (PDP-11) — flag (`--role`) or detection?
4. Notifications on backend switch — wanted, or too noisy?
5. Auth on the LAN server: none (single user, home LAN) with a size cap —
   confirm.
6. Phase 1 §5 sections: each needs review and approval.
