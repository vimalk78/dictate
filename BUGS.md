# Bug Fixes

Chronological list of bugs found and fixed in dictate.

---

### 1. CUDA detection broken, venv pollution, cublas not loading
**Date**: 2026-02-22 &ensp; **Commit**: `e80db51`

`has_cuda()` checked for the string "cuda" in a set of compute types
instead of querying the GPU. Venv was polluting system Python.
`nvidia-cublas-cu12` wasn't auto-installed, causing silent CPU fallback.

**Fix**: Proper CUDA detection, isolated venv, auto-install cublas,
launcher sets `LD_LIBRARY_PATH` for venv CUDA libs.

---

### 2. Audio device not picking up AirPods, silence threshold wrong
**Date**: 2026-02-22 &ensp; **Commit**: `a714491`

Default ALSA device didn't route Bluetooth mic correctly through
PipeWire. Silence threshold was hard-coded, causing false stops.

**Fix**: Prefer PipeWire audio device by name. Auto-calibrate silence
threshold from ambient noise level.

---

### 3. Whisper hallucinations on silence ("thanks for watching")
**Date**: 2026-02-23 &ensp; **Commit**: `15642b4`

Whisper generated phantom text when fed silence or very low audio.

**Fix**: Set `hallucination_silence_threshold=2` in transcribe calls.

---

### 4. Long transcription overflowing nvim command line
**Date**: 2026-02-22 &ensp; **Commit**: `0b4322c`

Full transcription text in nvim echo area caused "Press ENTER" prompt.

**Fix**: Show word count instead of full text.

---

### 5. Input group membership warning false positives
**Date**: 2026-02-23 &ensp; **Commit**: `f583e36`

Warning triggered even when user was already in the `input` group.

**Fix**: Check both `/etc/group` for membership AND current session
for active groups; only warn when user was added but hasn't relogged.

---

### 6. Socket recv buffer truncating long requests
**Date**: 2026-02-22 &ensp; **Commit**: `f1f2cad`

Client request was read with a fixed 1024-byte recv, dropping data
from long hint prompts.

**Fix**: Read until EOF (shutdown(SHUT_WR) from client).

---

### 7. `last_speech_time` race condition (initialized to None)
**Date**: 2026-02-22 &ensp; **Commit**: `f1f2cad`

`last_speech_time` was `None` at recording start, causing TypeError
on first silence check.

**Fix**: Initialize to current time at recording start.

---

### 8. Speech threshold too high from noisy calibration
**Date**: 2026-02-22 &ensp; **Commit**: `f1f2cad`

Noisy ambient during calibration (e.g. AirPods connecting) set
threshold so high that real speech was ignored.

**Fix**: Cap speech threshold at 0.15.

---

### 9. Keyboard disconnect crashes PTT mode
**Date**: 2026-03-11 &ensp; **Commit**: `5e78d69`

KVM switch or USB disconnect caused unhandled `OSError`, crashing
the PTT event loop.

**Fix**: Catch `OSError` and poll for keyboard reconnect.

---

### 10. Other keyboards stop working when one disconnects
**Date**: 2026-03-13 &ensp; **Commit**: `89b7265`

Disconnect handler caught the error at selector level, killing
monitoring for all keyboards.

**Fix**: Catch `OSError` per device — other keyboards keep working
while the disconnected one is unregistered.

---

### 11. Mic disconnect during PipeWire route switching
**Date**: 2026-03-25 &ensp; **Commit**: `73fcf1c`

PipeWire switching audio routes (e.g. AirPods connecting) caused
calibration to pick up transient noise, setting a bad threshold.

**Fix**: Retry calibration when ambient RMS > 0.03 (catches routing
transients). Detect mic disconnect via sustained zero RMS.

---

### 12. Mic not ready at boot (PipeWire not initialized)
**Date**: 2026-03-25 &ensp; **Commit**: `dd2fbe4`

At boot, PipeWire may not be routing audio yet. Calibration got
rms=0.0 and failed.

**Fix**: Retry calibration up to 5 times (2s apart), re-detecting
the audio device on each attempt. Add `-u` for unbuffered Python
output. Improve systemd ordering for PipeWire readiness.

---

### 13. wl-copy zombies and PTT freeze after KVM switch
**Date**: 2026-03-26 &ensp; **Commit**: `3a4819d`

`subprocess.run` for wl-copy blocked the PTT event loop. Zombie
wl-copy processes accumulated.

**Fix**: Use `Popen` (non-blocking). Kill previous wl-copy before
spawning a new one.

---

### 14. PTT blocked on keyboard reconnect after KVM switch
**Date**: 2026-03-27 &ensp; **Commit**: `685284c`

Blocking reconnect poll loop froze PTT while waiting for USB
re-enumeration.

**Fix**: Timeout-based selector with non-blocking reconnect. Discover
new keyboards every 2s without blocking the event loop.

---

### 15. Mic health monitor notification spam
**Date**: 2026-03-28 &ensp; **Commit**: `28addaf`

Single momentary silence triggered disconnect/reconnect notification
flurry during Zoom calls or browser media playback.

**Fix**: Require 6 consecutive silent checks (30s) before declaring
mic lost. One non-silent check resets the counter.

---

### 16. Whisper truncating transcription on natural pauses
**Date**: 2026-04-01 &ensp; **Commit**: `6b677aa`

Natural speech pauses triggered Whisper's internal silence detection,
causing it to stop transcribing mid-sentence.

**Fix**: Raise `hallucination_silence_threshold` from 2 to 5, increase
`no_speech_threshold` to 0.8, disable `condition_on_previous_text`.

---

### 17. install/update scripts overwriting user config and hints
**Date**: 2026-04-03 &ensp; **Commit**: `32b71f0`

Running install.sh or update.sh overwrote user-edited hints files
and config.

**Fix**: Skip files that already exist. Only copy service files when
content has changed.

---

### 18. Dual audio stream starvation in daemon PTT mode
**Date**: 2026-04-04 &ensp; **Commit**: `05d747b`

Daemon opened a second audio stream for recording while prebuf_stream
was already running. PipeWire sometimes starved the second stream,
causing "no speech detected." Also, `silence_secs=3` and `wait_secs=10`
cut recordings short before the user released the key.

**Fix**: Use single prebuf_stream for both pre-buffering and recording.
PTT mode uses key-release (STOP_FLAG) instead of silence timeout.

---

### 19. STOP_FLAG race condition — recording stuck for minutes
**Date**: 2026-04-08 &ensp; **Commit**: `6f5cbf6`

When user pressed and released the key quickly, the daemon cleared the
STOP_FLAG as "stale" before the recording loop started checking it.
The recording then hung until `wait_secs` (300s in PTT mode) expired.
Combined with audio device disconnect (KVM switch), the daemon
accumulated 15+ minutes of silence, transcribing 49 segments of
hallucinated "Thank you."

**Root cause**: Line 628 cleared STOP_FLAG before line 643 started
polling. If key-release happened in this window, the signal was lost.

**Fix**: Compare STOP_FLAG mtime against recording start time — only
react to flags created after the recording started. Stale flags are
identified by `mtime < rec_start_wall` and cleaned up without acting.

---

### 20. No hard timeout — stuck recording on device disconnect
**Date**: 2026-04-08 &ensp; **Commit**: `6f5cbf6`

When the audio device disconnected (KVM switch), the prebuf_callback
kept running with near-zero RMS but the `wait_secs=300` timeout in
the callback never fired fast enough. No mechanism in the main polling
loop enforced a maximum recording duration.

**Fix**: Add `hard_timeout` (default 120s, configurable via
`max_recording_secs` in config.toml) in the main polling loop.
Recording terminates unconditionally after this deadline.

---

### 21. Mic-lost didn't abort active recording
**Date**: 2026-04-08 &ensp; **Commit**: `6f5cbf6`

When mic_monitor declared the mic dead (30s of silence), any active
recording continued accumulating garbage audio. The recording and
mic monitoring were independent state machines with no interaction.

**Fix**: mic_monitor now sets `rec_active[0] = False` when declaring
mic-lost during an active recording, aborting it immediately.

---

### 22. rec_start_wall recorded too late — mtime check defeated
**Date**: 2026-04-08 &ensp; **Commit**: *(pending)*

Found by TLA+ model checker (TLC). The mtime fix for bug #19 recorded
`rec_start_wall` after reading the request, parsing JSON, sending status,
etc. (~50 lines of processing after `accept()`). If the user released the
key during this window, the STOP_FLAG mtime was earlier than
`rec_start_wall`, so the daemon incorrectly classified the legitimate
flag as stale — the same stuck-recording symptom as bug #19.

**Root cause**: `rec_start_wall = time.time()` was at line 634, but
`server.accept()` was at line 583. The key-release could happen anywhere
in that gap.

**Fix**: Snapshot wall-clock immediately after `server.accept()`, before
any request processing. Since key-up always happens after key-down, and
key-down triggers the socket connection, `accept()` time is always ≤
key-up time.
