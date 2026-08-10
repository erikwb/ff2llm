# AI model assets (local, no Ollama)

Fetched by `scripts/download_ai_assets.sh`. Large files are gitignored.

| Path | Purpose |
|------|---------|
| `llm/gemma-4-E2B-it-Q4_0.gguf` | Gemma 4 E2B chat (NPC replies) via in-process libllama |
| `whisper/ggml-base.en.bin` | English STT for `vendor/whisper/whisper-cli` |
| `piper/voices/*.onnx` | Legacy Piper (unused) |

## Kokoro TTS (PyTorch ROCm)

NPC speech uses **hexgrad Kokoro-82M** on the GPU via a long-lived worker:

```text
scripts/kokoro_rocm_worker.py   # warm process, one SYNTH per line
.venv-tts/                      # kokoro + spaCy; system python-pytorch-rocm
```

Setup once:

```bash
sudo pacman -S python-pytorch-rocm espeak-ng uv
./scripts/setup_kokoro_rocm.sh
```

Speaker map (sid → voice name) is in `src/ai/tts_host.c` / `voice_profile.zig`.

## System packages

```bash
sudo pacman -S llama-cpp python-pytorch-rocm espeak-ng uv
```

## Re-download / re-setup

```bash
./scripts/download_ai_assets.sh   # LLM + whisper weights
./scripts/setup_kokoro_rocm.sh    # Kokoro ROCm worker env
```
