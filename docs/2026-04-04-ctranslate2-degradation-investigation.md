# CTranslate2 Degradation Investigation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Investigate and isolate why Whisper transcription quality degrades in a long-running daemon process (truncation + wrong words), determine if the root cause is in CTranslate2, and build evidence for a bug report.

**Architecture:** The dictate daemon loads a `WhisperModel` once and calls `model.transcribe()` for every request. Over time (or after PC suspend/resume), transcription degrades. Restarting the daemon fixes it. CTranslate2's C++ engine maintains KV cache and GPU memory allocators that persist across calls — prime suspects for state corruption.

**Tech Stack:** Python, faster-whisper, CTranslate2 (C++ with Python bindings), CUDA, systemd

---

## Background

### Observed symptoms
- Transcription truncated: audio=7.4s but only partial speech transcribed
- Wrong words: "ok" transcribed as "done"
- Only 1 segment returned even when audio contains more speech
- Restarting the daemon immediately fixes both issues

### Suspected root causes (from source code analysis)
1. **CTranslate2 KV cache** — encoder-decoder attention cache persists across `transcribe()` calls, never explicitly cleared
2. **CTranslate2 caching memory allocators** — GPU/CPU memory pools retain allocated chunks between calls; after suspend/resume, pool entries may reference invalid GPU memory
3. **CUDA context corruption** — GPU memory may be remapped by driver after suspend; C++ pointers in cache reference old addresses

### Key CTranslate2 APIs discovered
- `model.model.unload_model(to_cpu=False)` — unloads model, keeps runtime context
- `model.model.load_model(keep_cache=False)` — reloads model, `keep_cache=False` clears cache
- Segment metrics: `avg_logprob`, `compression_ratio`, `no_speech_prob`, `temperature`

---

## Task 1: Add quality metrics to transcription log

**Why:** We need baseline data to know what "healthy" vs "degraded" looks like. Currently we log timestamp and text. We need `avg_logprob`, `no_speech_prob`, `compression_ratio`, and segment coverage ratio per transcription.

**Files:**
- Modify: `dictate` — `transcribe_audio()` (~line 284) and log write (~line 586)

- [ ] **Step 1: Extend `transcribe_audio()` to return metrics alongside text**

Change the return value to include metrics. The function currently returns just `text`. Change it to return `(text, metrics_dict)` where metrics_dict contains:
```python
metrics = {
    "audio_duration": audio_duration,
    "seg_count": len(seg_list),
    "coverage": seg_list[-1].end / audio_duration if seg_list else 0,
    "avg_logprob": np.mean([s.avg_logprob for s in seg_list]) if seg_list else 0,
    "no_speech_prob": np.mean([s.no_speech_prob for s in seg_list]) if seg_list else 0,
    "compression_ratio": np.mean([s.compression_ratio for s in seg_list]) if seg_list else 0,
    "transcribe_time": t1 - t0,
}
```

Also print metrics in the console log:
```python
print(f"  [metrics] coverage={metrics['coverage']:.2f}, avg_logprob={metrics['avg_logprob']:.2f}, no_speech={metrics['no_speech_prob']:.2f}")
```

- [ ] **Step 2: Update all callers of `transcribe_audio()`**

There are 3 call sites:
1. `serve()` (~line 581): `text = transcribe_audio(...)` → `text, metrics = transcribe_audio(...)`
2. `serve_tcp()` (~line 410): same change
3. `push_to_talk()` (~line 834): this calls `model.transcribe()` directly, not `transcribe_audio()`. Change it to use `transcribe_audio()` for consistency.

- [ ] **Step 3: Write metrics to transcription log**

In `serve()` (~line 586), change the log write from:
```python
lf.write(f"{datetime.now().isoformat()}\t{text}\n")
```
to:
```python
lf.write(f"{datetime.now().isoformat()}\tcov={metrics['coverage']:.2f}\tlogp={metrics['avg_logprob']:.2f}\tnsp={metrics['no_speech_prob']:.2f}\t{text}\n")
```

- [ ] **Step 4: Deploy and verify**

```bash
bash update.sh
dictate --once  # speak a sentence
tail -3 ~/.local/share/dictate/transcriptions.log
```

Verify the log line now contains `cov=`, `logp=`, `nsp=` fields.

- [ ] **Step 5: Commit**

```bash
git add dictate
git commit -m "feat: add quality metrics to transcription log for degradation tracking"
```

---

## Task 2: Add `dictate --reload-model` command

**Why:** This is the critical diagnostic tool. When degradation happens, running `dictate --reload-model` will tell the daemon to fully recreate the `WhisperModel` object — fresh C++ engine, fresh CUDA allocator, fresh KV cache. Takes ~3 seconds. If this fixes the quality WITHOUT restarting the process, we've proven the bug is in CTranslate2's internal state (model weights, KV cache, or allocator), not in CUDA context or the audio pipeline.

Two levels of reset:
1. **Full recreation** (default): `model = WhisperModel(...)` — new C++ object, new allocator, everything fresh. ~3s.
2. **Partial reload**: `model.model.unload_model()` + `model.model.load_model(keep_cache=False)` — reloads weights but keeps "runtime context". Faster but may not clear allocator state.

We use full recreation since 3 seconds is negligible.

**Files:**
- Modify: `dictate` — `serve()` socket handler, `main()` argparse

- [ ] **Step 1: Add `--reload-model` argument to argparse**

In `main()`, add:
```python
parser.add_argument("--reload-model", action="store_true",
    help="Tell daemon to fully recreate the Whisper model (clears all CTranslate2 state)")
```

- [ ] **Step 2: Add `--reload-model` handler in `main()`**

After the `--stop` handler, add:
```python
if args.reload_model:
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCK_PATH)
        sock.sendall(json.dumps({"command": "reload_model"}).encode())
        sock.shutdown(socket.SHUT_WR)
        resp = sock.recv(4096).decode().strip()
        print(resp)
        sock.close()
    except ConnectionRefusedError:
        print("No daemon running.")
    return
```

- [ ] **Step 3: Handle `reload_model` command in `serve()` request loop**

In the `serve()` function, after parsing `req`, check for the command. The daemon needs to know the model name, device, and compute type to recreate it — store these when initially loading:
```python
if req.get("command") == "reload_model":
    if model is not None:
        print("Recreating model from scratch...")
        import time as _time
        t0 = _time.monotonic()
        del model
        model = WhisperModel(model_name, device=model_device, compute_type=model_compute)
        t1 = _time.monotonic()
        from datetime import datetime
        with open(LOG_PATH, "a") as lf:
            lf.write(f"\n--- MODEL RECREATED  PID={os.getpid()}  {t1-t0:.1f}s  {datetime.now().isoformat()} ---\n")
        print(f"Model recreated in {t1-t0:.1f}s.")
        conn.sendall(f"Model recreated in {t1-t0:.1f}s.\n".encode())
    else:
        conn.sendall(b"No local model (forwarding mode).\n")
    continue
```

- [ ] **Step 4: Deploy and test**

```bash
bash update.sh
dictate --reload-model
```

Expected output: `Model reloaded successfully.`
Check log: `tail -3 ~/.local/share/dictate/transcriptions.log` should show `--- MODEL RELOADED ---` marker.

- [ ] **Step 5: Commit**

```bash
git add dictate
git commit -m "feat: add --reload-model to clear CTranslate2 cache without full restart"
```

---

## Task 3: Add suspend/resume detection

**Why:** We suspect suspend/resume corrupts model state. We need to detect when it happens so we can correlate it with degradation in the logs.

**Files:**
- Modify: `dictate` — `prebuf_callback()` in `serve()` (~line 444)

- [ ] **Step 1: Track timestamps in prebuf_callback to detect time jumps**

In `serve()`, before the `prebuf_callback` definition, add:
```python
import time as _time
last_callback_time = [_time.monotonic()]  # mutable container for closure
```

Modify `prebuf_callback`:
```python
def prebuf_callback(indata, frames, time_info, status):
    now = _time.monotonic()
    gap = now - last_callback_time[0]
    if gap > 10.0:  # >10s gap means system was suspended
        print(f"\n⚠ SUSPEND DETECTED: {gap:.0f}s gap in audio callback")
        from datetime import datetime
        with open(LOG_PATH, "a") as lf:
            lf.write(f"\n--- SUSPEND/RESUME DETECTED  gap={gap:.0f}s  {datetime.now().isoformat()} ---\n")
    last_callback_time[0] = now
    pre_buffer.append(indata.copy())
    recent_rms.append(np.sqrt(np.mean(indata ** 2)))
```

- [ ] **Step 2: Deploy and test**

```bash
bash update.sh
```

To test without actually suspending: check that normal operation doesn't trigger false positives. Look at logs after a few transcriptions — should see no suspend warnings.

To test the real thing: suspend the PC (`systemctl suspend`), resume, then check:
```bash
journalctl --user -u dictate.service --since "5 min ago" --no-pager | grep SUSPEND
tail -20 ~/.local/share/dictate/transcriptions.log | grep SUSPEND
```

- [ ] **Step 3: Commit**

```bash
git add dictate
git commit -m "feat: detect suspend/resume via audio callback time gap"
```

---

## Task 4: Collect baseline metrics data

**Why:** Before building auto-detection, we need to know what healthy and degraded metrics look like. This is a manual data collection step.

- [ ] **Step 1: Use dictate normally for a day**

Do normal transcription work. The metrics are now logged.

- [ ] **Step 2: After degradation occurs, capture the data**

When truncation/wrong words happen:
```bash
# Check transcription log for metric trends
tail -30 ~/.local/share/dictate/transcriptions.log

# Note the metrics BEFORE and AFTER degradation started
# Look for: coverage dropping, avg_logprob dropping, no_speech_prob rising
```

- [ ] **Step 3: Test `dictate --reload-model` during degradation**

When quality is bad:
```bash
dictate --reload-model
dictate --once  # test immediately after reload — is it fixed?
```

Record the result:
- If fixed → CTranslate2 model state is the root cause. Proceed to Task 6 (CTranslate2 bug report).
- If NOT fixed → the issue is in CUDA context, audio pipeline, or something else. Needs different investigation.

- [ ] **Step 4: Test after suspend/resume specifically**

Suspend, resume, immediately test:
```bash
dictate --once  # right after resume — quality ok?
# Use normally for a while — does it degrade?
```

This tells us if suspend is the trigger or if it's purely uptime-based.

- [ ] **Step 5: Document findings**

Update this file with the collected data. Example format:
```
## Baseline Data (collected YYYY-MM-DD)

### Healthy transcriptions
- coverage: 0.95-1.0
- avg_logprob: -0.3 to -0.5
- no_speech_prob: < 0.1

### Degraded transcriptions  
- coverage: 0.7-0.85
- avg_logprob: -0.8 to -1.2
- no_speech_prob: > 0.3

### --reload-model test
- Fixed degradation: YES / NO
```

---

## Task 5: Build auto-detection and recovery

**Why:** Once we know the metric thresholds from Task 4, we can auto-detect degradation and either reload the model or restart the daemon.

**Depends on:** Task 4 results. The exact thresholds and recovery action depend on what we learn.

**Files:**
- Modify: `dictate` — `serve()` function

- [ ] **Step 1: Add rolling metrics tracker in serve()**

```python
from collections import deque
recent_metrics = deque(maxlen=10)  # last 10 transcriptions
```

After each transcription, append the metrics dict.

- [ ] **Step 2: Add degradation check after each transcription**

After appending to `recent_metrics`, check:
```python
def check_health(recent_metrics):
    if len(recent_metrics) < 3:
        return True  # not enough data
    last_3 = list(recent_metrics)[-3:]
    # Thresholds TBD from Task 4 data
    low_coverage = sum(1 for m in last_3 if m["coverage"] < COVERAGE_THRESHOLD)
    low_logprob = sum(1 for m in last_3 if m["avg_logprob"] < LOGPROB_THRESHOLD)
    if low_coverage >= 2 or low_logprob >= 2:
        return False
    return True
```

- [ ] **Step 3: Auto-recover when degradation detected**

If `check_health()` returns False:
```python
if not check_health(recent_metrics):
    print("⚠ Degradation detected! Recreating model...")
    del model
    model = WhisperModel(model_name, device=model_device, compute_type=model_compute)
    recent_metrics.clear()
    with open(LOG_PATH, "a") as lf:
        lf.write(f"\n--- AUTO-RECREATE (degradation detected)  {datetime.now().isoformat()} ---\n")
    notify("Dictate: model recreated", "Quality degradation detected — fresh model loaded.", "dialog-warning")
```

- [ ] **Step 4: Deploy and test**

```bash
bash update.sh
```

- [ ] **Step 5: Commit**

```bash
git add dictate
git commit -m "feat: auto-detect transcription degradation and reload model"
```

---

## Task 6: Isolate and report CTranslate2 bug

**Why:** If `--reload-model` fixes degradation (Task 4, Step 3), we have evidence that CTranslate2's internal state corrupts over time. This is worth reporting.

**Depends on:** Task 4 confirming that model reload fixes the issue.

- [ ] **Step 1: Build minimal reproducer script**

Create `tests/ctranslate2-state-test.py` — a standalone script that:
1. Loads a WhisperModel
2. Transcribes a known WAV file (record one: `dictate --once > /dev/null` while saving raw audio)
3. Loops N times, comparing output consistency
4. Optionally simulates suspend by calling `ctranslate2` internal methods to corrupt/flush GPU state

```python
"""Minimal reproducer: CTranslate2 Whisper model state degradation.

Tests whether repeated transcribe() calls on the same audio produce
consistent results, and whether unload_model()+load_model() resets state.
"""
from faster_whisper import WhisperModel
import numpy as np
import soundfile as sf

audio, sr = sf.read("test_audio.wav")
if sr != 16000:
    # resample if needed
    pass

model = WhisperModel("large-v3-turbo", device="cuda", compute_type="int8")

baseline = None
for i in range(100):
    segments, info = model.transcribe(audio, language="en", hallucination_silence_threshold=2)
    text = " ".join(s.text for s in segments).strip()
    logprob = ...  # capture metrics
    
    if baseline is None:
        baseline = text
    elif text != baseline:
        print(f"DRIFT at iteration {i}: '{text}' != '{baseline}'")
        
        # Test: does reload fix it?
        model.model.unload_model()
        model.model.load_model(keep_cache=False)
        segments2, _ = model.transcribe(audio, language="en", hallucination_silence_threshold=2)
        text2 = " ".join(s.text for s in segments2).strip()
        print(f"After reload: '{text2}'")
```

- [ ] **Step 2: Run the reproducer**

```bash
python tests/ctranslate2-state-test.py
```

If output drifts → CTranslate2 bug confirmed with a clean reproducer.
If output is stable → degradation requires suspend/resume or long uptime to trigger. Note this in the bug report.

- [ ] **Step 3: File bug report on CTranslate2 GitHub**

Repository: https://github.com/OpenNMT/CTranslate2

Include:
- System info (GPU, CUDA version, CTranslate2 version, OS)
- Description: Whisper model quality degrades in long-running process. `unload_model()` + `load_model(keep_cache=False)` fixes it.
- Reproducer script
- Log data showing metric degradation over time
- Hypothesis: KV cache or caching memory allocator state corruption

- [ ] **Step 4: If we can identify the exact C++ code path, submit a PR**

The CTranslate2 source areas to investigate:
- `src/models/whisper.cc` — generate() implementation
- `src/allocator.h` / `src/cuda/allocator.cc` — caching allocator
- KV cache management in the Transformer decoder

---

## Progress Tracking

| Task | Status | Notes |
|------|--------|-------|
| 1. Quality metrics logging | Not started | |
| 2. `--reload-model` command | Not started | |
| 3. Suspend/resume detection | Not started | |
| 4. Baseline data collection | Not started | Needs Tasks 1-3 deployed first |
| 5. Auto-detection & recovery | Not started | Needs Task 4 data |
| 6. CTranslate2 bug report | Not started | Needs Task 4 confirmation |
