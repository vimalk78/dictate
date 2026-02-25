# Parakeet ASR Evaluation for Dictate

Evaluated: 2026-02-25

## What is Parakeet

NVIDIA's Parakeet is a family of ASR models built on the FastConformer encoder architecture (optimized Conformer with 8x depthwise-separable convolutional downsampling), paired with different decoder heads.

### Variants by decoder

| Variant | Decoder | Key Trait |
|---------|---------|-----------|
| Parakeet-CTC | Connectionist Temporal Classification | Simplest. Non-autoregressive. |
| Parakeet-RNNT | RNN-Transducer | Autoregressive. Supports streaming. |
| Parakeet-TDT | Token-and-Duration Transducer | Jointly predicts tokens AND durations. Flagship. |
| Parakeet-TDT_CTC | Hybrid TDT + CTC | Both heads on one encoder. Choose CTC (faster) or TDT (more accurate) at inference. |

### Variants by size

| Model | Parameters | Languages |
|-------|-----------|-----------|
| parakeet-tdt_ctc-110m | 110M | English only |
| parakeet-tdt-0.6b-v2 | 600M | English only. Top of HF Open ASR leaderboard (6.05% avg WER). |
| parakeet-tdt-0.6b-v3 | 600M | 25 European languages. Auto language detection. |
| parakeet-ctc-1.1b | 1.1B | English only |
| parakeet-tdt_ctc-1.1b | 1.1B | English only |

License: CC-BY-4.0 (permissive, commercial use allowed, attribution required).

## Accuracy vs Whisper

Parakeet wins decisively on English:

| Model | Avg WER (HF Open ASR Leaderboard) |
|-------|------|
| Parakeet-TDT-0.6b-v2 | **6.05%** |
| Whisper large-v3 | ~10-12% |
| Whisper base/small | ~19-20% |

Specific benchmarks (Parakeet-TDT-0.6b-v2):
- LibriSpeech test-clean: 1.69% WER
- LibriSpeech test-other: 3.19% WER
- Noise robustness: 21.58% WER vs Whisper's 29.80%

GPU speed: RTFx ~3380 for Parakeet vs ~60-100 for faster-whisper. Roughly 50x faster.

## Ways to Run It

| Path | Dependencies | Weight |
|------|-------------|--------|
| onnx-asr | numpy + onnxruntime (~122 KB wheel) | Very light |
| HuggingFace Transformers | PyTorch + transformers (CTC models only) | Medium |
| NeMo | PyTorch + NeMo full ASR stack | Very heavy |
| sherpa-onnx | C++ core + Python bindings | Light |

## Input Requirements

- Sample rate: 16 kHz
- Channels: mono
- Format: float32 numpy arrays or WAV/FLAC files
- Same as dictate's existing audio pipeline.

## Fit Analysis for Dictate

### What fits cleanly

- **Audio format**: 16kHz mono float32 — identical to current pipeline
- **Record-then-transcribe**: Parakeet is batch/offline, matches our architecture (record until silence, then transcribe)
- **Daemon/client/push-to-talk structure**: model-agnostic, no changes needed
- **No hallucination problem**: Parakeet's transducer architecture doesn't hallucinate on silence like Whisper, so `hallucination_silence_threshold` becomes unnecessary

### What doesn't fit

#### 1. No `initial_prompt` — hints system breaks (dealbreaker)

Whisper's encoder-decoder lets you condition the decoder on a text prefix. Parakeet is a transducer/CTC — no text input at decode time. The entire hints system would stop working:
- `load_hints()`
- Per-project `.dictate-hints.d/`
- Global `~/.config/dictate/hints.d/`

NeMo has "word boosting" (phrase biasing during beam search) as a partial alternative, but:
- Only available through full NeMo framework (massive dependency)
- Not available through onnx-asr (the lightweight path)
- Less flexible than Whisper's prompt conditioning
- Requires beam search, not greedy decoding

#### 2. Dependency trade-off is unfavorable

| Path | Hints support | Practical? |
|------|--------------|------------|
| onnx-asr (light) | No | Yes, but loses core feature |
| NeMo (heavy) | Yes (word boosting) | Far heavier than current faster-whisper + ctranslate2 |
| HuggingFace | No, CTC only | CTC models less accurate than TDT |

The lightweight path can't do hints. The path that can do hints is far heavier than our current stack.

#### 3. CPU inference is weaker

faster-whisper via CTranslate2 has highly optimized int8 CPU kernels. `--cpu` mode works well today. Parakeet on CPU through ONNX Runtime is functional but less mature and slower.

#### 4. Language support is narrower

- Whisper: 99 languages
- Parakeet v2: English only
- Parakeet v3: 25 European languages
- No Hindi, Japanese, Arabic, CJK, etc.

#### 5. API differences

Current `transcribe_audio()` calls:
```python
model.transcribe(audio, language=..., initial_prompt=..., hallucination_silence_threshold=2)
```

Parakeet APIs differ:
- NeMo: `model.transcribe(["file.wav"])` — expects file paths
- onnx-asr: `model.recognize("file.wav")` — expects file paths
- Would need temp file writes or API adaptation
- Return types differ (no segment iterator)

#### 6. Jetson/ctranslate2 pipeline replacement

The entire install pipeline (build-ctranslate2.sh, Jetson aarch64 support, LD_LIBRARY_PATH for CUDA) would need full replacement.

## Conclusion

Parakeet is better at English accuracy (6% vs 10-12% WER) and GPU speed (50x faster), but it's a poor fit for dictate because:

1. **Hints are a core feature** and there's no lightweight equivalent in Parakeet
2. Either lose hints entirely (onnx-asr) or massively bloat the install (NeMo) for an inferior version
3. CPU mode gets worse, language coverage shrinks
4. Install pipeline needs full replacement for marginal benefit

Not recommended unless willing to drop the hints system or commit to the NeMo dependency.
