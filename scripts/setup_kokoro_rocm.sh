#!/usr/bin/env bash
# One-shot setup for PyTorch-ROCm Kokoro TTS worker.
# Requires: pacman -S python-pytorch-rocm espeak-ng
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! python3 -c "import torch; assert torch.cuda.is_available()" 2>/dev/null; then
  echo "error: system torch has no ROCm device. Install: sudo pacman -S python-pytorch-rocm" >&2
  exit 1
fi

if ! command -v uv >/dev/null; then
  echo "error: need uv (sudo pacman -S uv)" >&2
  exit 1
fi

echo "== venv (.venv-tts, system-site-packages for ROCm torch) =="
rm -rf .venv-tts
uv venv --python /usr/bin/python3 --system-site-packages .venv-tts

echo "== kokoro + deps (do not install pip torch — use system ROCm) =="
uv pip install --python .venv-tts/bin/python kokoro soundfile loguru
# Drop any CUDA torch wheels uv may have pulled so system ROCm wins.
rm -rf .venv-tts/lib/python*/site-packages/torch \
       .venv-tts/lib/python*/site-packages/torch-*.dist-info \
       .venv-tts/lib/python*/site-packages/nvidia 2>/dev/null || true

echo "== spaCy English model (misaki G2P; avoid spacy.cli.download→uv) =="
uv pip install --python .venv-tts/bin/python \
  "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"

echo "== verify =="
.venv-tts/bin/python - <<'PY'
import torch
from kokoro import KPipeline
assert torch.cuda.is_available(), "ROCm not visible"
print("torch", torch.__version__, "hip", getattr(torch.version, "hip", None))
print("gpu", torch.cuda.get_device_name(0))
pipe = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M", device="cuda")
print("kokoro pipeline ok")
PY

echo
echo "Done. Game will start: .venv-tts/bin/python scripts/kokoro_rocm_worker.py"
echo "Smoke:"
echo "  printf 'SYNTH am_michael 1.0 /tmp/t.wav Hello from Baron.\\nQUIT\\n' | .venv-tts/bin/python scripts/kokoro_rocm_worker.py"
