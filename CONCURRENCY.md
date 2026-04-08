# Dictate Daemon — Concurrency Specification

This document specifies all concurrent execution contexts, shared mutable
state, and synchronization in the `serve()` function.  It is written so
that a reader can verify, by inspection, that no race condition leads to a
stuck daemon or lost recording.

## 1  Execution Contexts

There are exactly four concurrent execution contexts inside `serve()`:

| ID | Context | Created at | Runs on |
|----|---------|-----------|---------|
| **M** | Main loop — `while True: server.accept()` | serve() entry | Main thread |
| **C** | `prebuf_callback(indata, ...)` | sounddevice InputStream | PortAudio callback thread |
| **H** | `mic_monitor()` | `threading.Thread(..., daemon=True)` | Daemon thread |
| **S** | Signal handlers (`on_resume`, `cleanup`) | `signal.signal(...)` | Main thread (async) |

External to the daemon process:

| ID | Context | Runs in |
|----|---------|---------|
| **P** | PTT client (`ptt_client()`) | Separate process (dictate-ptt.service) |

**P** communicates with **M** via Unix socket and the STOP_FLAG file.

## 2  Shared Mutable State

### 2.1  Recording lifecycle (boxed scalars in single-element lists)

| Variable | Writers | Readers |
|----------|---------|---------|
| `rec_active[0]` | **M** (set True/False), **C** (set False on timeout), **H** (set False on mic-lost) | **M** (poll loop), **C** (guard) |
| `rec_buffer` (list) | **C** (append), **M** (clear, concatenate) | **M** (read after recording) |
| `rec_speech_detected[0]` | **C** (set True), **M** (set True on STOP_FLAG, set False on init) | **C** (branch), **M** (read after recording) |
| `rec_last_speech[0]` | **C** (update on speech), **M** (init) | **C** (silence timeout) |
| `rec_start[0]` | **M** (init) | **C** (wait timeout) |
| `rec_max_rms[0]` | **C** (update), **M** (init) | **M** (logging) |
| `rec_callbacks[0]` | **C** (increment), **M** (init) | **M** (logging) |
| `rec_silence_secs[0]` | **M** (init) | **C** (timeout comparison) |
| `rec_wait_secs[0]` | **M** (init) | **C** (timeout comparison) |

### 2.2  Mic health

| Variable | Writers | Readers |
|----------|---------|---------|
| `speech_threshold` | **H** (from calibrate_mic) | **C** (threshold comparison) |
| `audio_dev` | **H** (from calibrate_mic) | **H** (passed to calibrate_mic) |
| `mic_healthy` | **H** (set True/False) | **H** (branch) |
| `recent_rms` (deque) | **C** (append) | **H** (snapshot via `list()`) |

### 2.3  Pre-buffer

| Variable | Writers | Readers |
|----------|---------|---------|
| `pre_buffer` (deque) | **C** (append) | **M** (snapshot via `list()`) |

### 2.4  Cross-process IPC

| Mechanism | Writer | Reader |
|-----------|--------|--------|
| STOP_FLAG file (`~/.local/share/dictate/stop`) | **P** (touch on key-up) | **M** (poll existence + mtime) |
| Unix socket | **P** (send JSON request) | **M** (recv in accept loop) |

## 3  Why Data Races Are Benign Under CPython GIL

All contexts run under CPython's GIL.  The GIL guarantees that:

- A single bytecode instruction executes atomically.
- `list.append()`, `list.clear()`, `deque.append()`, single-element list
  read/write (`x[0] = val`, `val = x[0]`) are each one bytecode op.

This means no **memory corruption** can occur.  However, the GIL does NOT
prevent **logical** races — e.g., a stale value being read one iteration
late.  The specification below addresses logical races.

## 4  Recording Lifecycle — State Machine

A recording goes through exactly these states:

```
IDLE  →  ACTIVE  →  STOPPING  →  PROCESSING  →  IDLE
```

### 4.1  IDLE → ACTIVE  (context: M)

**M** initializes all `rec_*` variables, then sets `rec_active[0] = True`.

**Invariant**: All `rec_*` variables are initialized BEFORE `rec_active[0]`
is set to True.  Since **C** only touches `rec_*` when `rec_active[0]` is
True (line 476: `if rec_active[0]:`), there is no window where **C** reads
partially-initialized state.

**Ordering guarantee**: Python's GIL ensures that the sequence of
assignments at lines 637–645 completes atomically w.r.t. any single
callback invocation (each callback acquires the GIL, sees either all-old
or all-new values).

### 4.2  ACTIVE  (contexts: M polls, C records, H monitors)

While `rec_active[0]` is True, three things happen concurrently:

1. **C** appends audio to `rec_buffer`, updates speech detection.
2. **M** polls for stop conditions every 100ms.
3. **H** checks mic health every 5s.

#### Stop conditions (any one terminates ACTIVE):

| Condition | Detected by | Sets `rec_active[0]` = False |
|-----------|-------------|-------------------------------|
| STOP_FLAG with mtime ≥ rec_start_wall | **M** (poll loop) | **M** |
| Silence after speech for `silence_secs` | **C** (callback) | **C** |
| No speech for `wait_secs` | **C** (callback) | **C** |
| Hard timeout (120s default) | **M** (poll loop) | **M** |
| Mic lost (30s silence in monitor) | **H** | **H** |

**Claim**: At least one stop condition fires within bounded time.

*Proof*:
- If **C** is running (audio device alive): either speech triggers
  silence_secs timeout, or no-speech triggers wait_secs timeout.
  Both are bounded.
- If **C** is NOT running (device dead): **H** detects mic-lost within
  30s and sets rec_active = False.  Independently, **M**'s hard timeout
  fires within 120s.
- The hard timeout in **M** is unconditional — it fires regardless of
  what **C** or **H** do.  This is the ultimate safety net.

Therefore recording always terminates.  ∎

### 4.3  ACTIVE → STOPPING  (one writer wins)

Multiple contexts may set `rec_active[0] = False` concurrently.
Under GIL, exactly one of them "goes first" and subsequent writes are
idempotent (False = False).  The first writer wins; no harm from
duplicates.

### 4.4  STOPPING → PROCESSING  (context: M only)

**M**'s poll loop exits.  At this point, **C** may execute one more
callback before observing `rec_active[0] == False`.  This is benign:

- One extra `rec_buffer.append()` adds at most 64ms of audio.  Harmless.
- One extra `rec_callbacks[0] += 1` makes the count off by 1.  Cosmetic.

**M** then reads `rec_buffer`, `rec_speech_detected[0]`, etc.
By the time **M** starts concatenating `rec_buffer`, **C** has
observed `rec_active[0] == False` and stopped appending.  Under GIL,
the list contents are consistent.

### 4.5  PROCESSING → IDLE  (context: M only)

**M** transcribes, sends result, loops back to `server.accept()`.
No other context touches recording state while **M** is processing
(C's guard `if rec_active[0]` is False, so C skips all rec_* writes).

## 5  STOP_FLAG Protocol — Race-Free Design

### 5.1  The old bug

Previously, **M** cleared the STOP_FLAG before starting a recording.
If **P** created the flag between clear and first poll, the flag was
lost → recording stuck.

### 5.2  The fix: mtime-based discrimination

**M** records `rec_start_wall = time.time()` before setting
`rec_active[0] = True`.  In the poll loop, **M** checks:

```python
flag_mtime = os.path.getmtime(STOP_FLAG)
if flag_mtime >= rec_start_wall:
    # Legitimate stop signal for THIS recording
else:
    # Stale flag from a previous recording — delete it
```

**Claim**: No legitimate STOP_FLAG is ever discarded.

*Proof*:
- **P** creates STOP_FLAG on key-up.  Key-up happens AFTER key-down.
  Key-down triggers the client_once() connection.  The daemon records
  `rec_start_wall` after accepting the connection.  Therefore:
  `flag_mtime (key-up time)  >  rec_start_wall (post-accept time)`
  always holds for a legitimate flag.

- A stale flag from a *previous* recording was created before
  `rec_start_wall`, so `flag_mtime < rec_start_wall`.  It is correctly
  identified as stale and deleted.

- Wall clock monotonicity: `time.time()` is monotonic within the
  ~100ms window between recording start and first poll.  NTP jumps
  are possible but would require a backward jump of >100ms during
  exactly this window — astronomically unlikely.  ∎

### 5.3  File operation atomicity

`Path.touch()` and `os.unlink()` are atomic on Linux (create and
unlink are single syscalls).  `os.path.exists()` + `os.path.getmtime()`
is NOT atomic — the file can disappear between the two calls.
The `try/except OSError` around this sequence handles this correctly.

## 6  Mic Monitor ↔ Recording Interaction

### 6.1  mic_monitor sets rec_active = False

When **H** declares mic-lost (after 30s of silence), it now checks
`rec_active[0]` and sets it to False if True.  This is safe because:

- `rec_active[0]` write is a single bytecode op (atomic under GIL).
- If **M** or **C** also set it to False concurrently, the writes are
  idempotent.
- **M** observes rec_active == False on next poll iteration (≤100ms).

### 6.2  speech_threshold updated by H, read by C

**H** may update `speech_threshold` via `calibrate_mic()` while **C**
reads it (line 482: `if rms > speech_threshold`).  Under GIL, **C**
sees either the old or the new value — never a torn read.  Both are
valid thresholds.  The worst case is one callback uses a stale
threshold, which affects at most 64ms of speech detection.  Benign.

## 7  pre_buffer and recent_rms — Snapshot Isolation

Both `pre_buffer` and `recent_rms` are `deque` objects written by **C**
and read by **M** (pre_buffer) or **H** (recent_rms).

Readers use `list(deque)` to take a snapshot.  Under GIL, `list(deque)`
iterates the deque while holding the GIL for each element copy.  A
concurrent `deque.append()` may add one element during iteration, but
since the deque has a fixed maxlen, the snapshot is off by at most one
element.  This is acceptable for both pre-buffer audio and RMS averaging.

## 8  PTT Client Concurrency

The PTT client (`ptt_client()`) has two execution contexts:

| Context | Description |
|---------|-------------|
| Event loop (main thread) | `selector.select()` → key events |
| Worker thread `t` | `client_once()` — socket communication with daemon |

Shared state: `t` (Thread ref), `result` (dict).

**Synchronization**: `t.join()` at line 894 is the single sync point.
After `t.join()` returns, the main thread reads `result`.  Since
`join()` establishes a happens-before relationship, the `result` dict
is safely published.

**Liveness concern**: If the daemon is stuck, `t.join()` blocks forever,
freezing the event loop.  This is now mitigated by the daemon-side fixes
(hard timeout + mic-lost abort), which ensure the daemon always responds
within bounded time.

## 9  Remaining Benign Races

These races exist but cause no harm:

1. **C** reads `rec_active[0]` one callback after **M** sets it False →
   one extra audio frame appended.  Harmless.

2. **H** reads `recent_rms` while **C** appends → RMS average off by
   one sample.  Harmless.

3. **C** reads `speech_threshold` during **H**'s update → one callback
   uses stale threshold.  64ms impact.  Harmless.

4. **M** reads `rec_callbacks[0]` after recording while **C** might have
   one more in-flight increment → count off by 1.  Cosmetic.

## 10  Liveness Summary

| Failure mode | Old behavior | New behavior |
|--------------|-------------|-------------|
| Audio device drops during recording | Stuck forever (callback stops, no timeout in M) | **H** aborts in 30s; hard timeout aborts in 120s |
| STOP_FLAG lost to race | Stuck until wait_secs (300s in PTT) | Cannot happen — mtime discrimination |
| PTT t.join() blocks | Frozen until daemon responds | Daemon always responds within max(30s, 120s) |
