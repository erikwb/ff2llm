#!/usr/bin/env bash
# Download vendored Piper/Whisper binaries + model weights (no AUR, no Ollama).
# Idempotent: skips files that already exist and look non-empty.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p vendor/piper vendor/whisper vendor/sherpa-onnx/lib models/llm models/whisper models/piper/voices models

need() {
  local f="$1" min="${2:-1}"
  if [[ -f "$f" ]]; then
    local sz
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    (( sz >= min )) && return 1
  fi
  return 0
}

echo "== Piper binary (rhasspy 2023.11.14-2) =="
if need vendor/piper/piper 1000000; then
  curl -L --fail -o /tmp/piper_linux_x86_64.tar.gz \
    "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz"
  tar -xzf /tmp/piper_linux_x86_64.tar.gz -C vendor/
  # extracts to vendor/piper/
fi
chmod +x vendor/piper/piper

echo "== Whisper.cpp CLI (v1.9.2 ubuntu x64) =="
if need vendor/whisper/whisper-bin-ubuntu-x64/whisper-cli 100000; then
  curl -L --fail -o /tmp/whisper-bin-ubuntu-x64.tar.gz \
    "https://github.com/ggerganov/whisper.cpp/releases/download/v1.9.2/whisper-bin-ubuntu-x64.tar.gz"
  tar -xzf /tmp/whisper-bin-ubuntu-x64.tar.gz -C vendor/whisper
fi
ln -sfn whisper-bin-ubuntu-x64/whisper-cli vendor/whisper/whisper-cli

echo "== Piper voices (Hugging Face rhasspy/piper-voices) =="
BASE="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0"
# NPC cast: male/female, US/UK for variety
voices=(
  "en/en_US/ryan/medium/en_US-ryan-medium"
  "en/en_US/amy/medium/en_US-amy-medium"
  "en/en_US/joe/medium/en_US-joe-medium"
  "en/en_US/lessac/medium/en_US-lessac-medium"
  "en/en_US/kristin/medium/en_US-kristin-medium"
  "en/en_GB/alan/medium/en_GB-alan-medium"
  "en/en_US/libritts/high/en_US-libritts-high"
  # Role variety
  "en/en_US/danny/low/en_US-danny-low"
  "en/en_US/hfc_male/medium/en_US-hfc_male-medium"
  "en/en_US/hfc_female/medium/en_US-hfc_female-medium"
  "en/en_US/bryce/medium/en_US-bryce-medium"
  "en/en_GB/cori/medium/en_GB-cori-medium"
  "en/en_GB/northern_english_male/medium/en_GB-northern_english_male-medium"
)
for path in "${voices[@]}"; do
  name=$(basename "$path")
  dest="models/piper/voices/$name"
  if need "${dest}.onnx" 1000000; then
    echo "  $name"
    curl -L --fail -o "${dest}.onnx" "${BASE}/${path}.onnx?download=true"
    curl -L --fail -o "${dest}.onnx.json" "${BASE}/${path}.onnx.json?download=true"
  else
    echo "  skip $name"
  fi
done

echo "== Whisper STT model (base.en) =="
if need models/whisper/ggml-base.en.bin 100000000; then
  curl -L --fail -o models/whisper/ggml-base.en.bin \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin?download=true"
fi

echo "== Gemma 4 E2B GGUF (Q4_0, ~2.8 GiB) =="
# Text chat brain for NPCs. In-process via system libllama (pacman llama-cpp).
if need models/llm/gemma-4-E2B-it-Q4_0.gguf 2000000000; then
  curl -L --fail -o models/llm/gemma-4-E2B-it-Q4_0.gguf \
    "https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf?download=true"
fi

echo "== sherpa-onnx shared libs (in-process Kokoro TTS, v1.13.4) =="
if need vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.so 1000000; then
  curl -L --fail -o /tmp/sherpa-onnx-linux-x64-shared-lib.tar.bz2 \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.4/sherpa-onnx-v1.13.4-linux-x64-shared-lib.tar.bz2"
  mkdir -p /tmp/sherpa-extract
  tar -xjf /tmp/sherpa-onnx-linux-x64-shared-lib.tar.bz2 -C /tmp/sherpa-extract
  # Package is sherpa-onnx-v*-linux-x64-shared-lib/lib/*
  libdir=$(find /tmp/sherpa-extract -type d -name lib | head -1)
  cp -a "$libdir"/* vendor/sherpa-onnx/lib/
fi
if need vendor/sherpa-onnx/include/sherpa-onnx-c-api.h 1000; then
  mkdir -p vendor/sherpa-onnx/include
  # Pin header to the same release as the shared lib (struct layout must match).
  curl -L --fail -o vendor/sherpa-onnx/include/sherpa-onnx-c-api.h \
    "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.4/sherpa-onnx/c-api/c-api.h"
fi

echo "== Kokoro English TTS model (kokoro-en-v0_19, ~330 MiB) =="
if need models/kokoro-en-v0_19/model.onnx 100000000; then
  curl -L --fail -o /tmp/kokoro-en-v0_19.tar.bz2 \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2"
  tar -xjf /tmp/kokoro-en-v0_19.tar.bz2 -C models/
fi

echo
echo "Done. Layout:"
echo "  vendor/whisper/whisper-cli"
echo "  vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.so"
echo "  models/kokoro-en-v0_19/model.onnx   # in-process TTS"
echo "  models/whisper/ggml-base.en.bin"
echo "  models/llm/gemma-4-E2B-it-Q4_0.gguf"
echo "  models/piper/voices/*.onnx          # legacy (unused if Kokoro loads)"
echo
echo "System dependency (official repos, not AUR):"
echo "  sudo pacman -S llama-cpp   # provides libllama for in-process LLM"
echo
echo "Smoke tests:"
echo "  # Kokoro is in-process (no CLI). Build + run the game from repo root."
echo "  zig build && ./zig-out/bin/ff4"
