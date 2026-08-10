#!/usr/bin/env python3
"""Long-lived Kokoro TTS worker — **warm on CPU** (default).

CPU synth for short NPC lines is ~0.25–0.7s once loaded. That beats a one-shot
GPU child (~3s reload) and does not peg the ROCm card (HIP busy-wait).

Protocol (stdin/stdout, one line per request):
  SYNTH <voice> <speed> <out_wav_path> <text...>
  → OK <path> <ms>ms   |   ERR <msg>
  PING → PONG …
  QUIT → BYE

Prints READY once the model is warm.

Env (optional):
  FF4_TTS_GPU_CHILD=1  — use a one-shot GPU subprocess per line (slow cold start;
                         only useful for very long text; parent still never holds HIP)
"""
from __future__ import annotations

import os
import sys
import time
import traceback


def main() -> int:
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    import numpy as np
    import soundfile as sf
    import torch
    from kokoro import KPipeline

    # Default: stay on CPU forever. HIP is never initialized → GPU stays free for Gemma.
    gpu_child = os.environ.get("FF4_TTS_GPU_CHILD", "").strip() in ("1", "true", "yes")

    print("loading Kokoro-82M on CPU...", file=sys.stderr, flush=True)
    t0 = time.time()
    pipe = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M", device="cpu")
    with torch.inference_mode():
        for _g, _p, audio in pipe("Ready.", voice="am_michael", speed=1.0):
            _ = audio
    # A few threads help CPU convs without thrashing the machine.
    try:
        torch.set_num_threads(max(1, min(4, os.cpu_count() or 4)))
    except Exception:
        pass
    print(f"ready in {time.time() - t0:.1f}s", file=sys.stderr, flush=True)
    print(f"READY cpu gpu_child={int(gpu_child)}", flush=True)

    self_py = sys.executable
    self_script = os.path.abspath(__file__)

    for raw in sys.stdin:
        line = raw.rstrip("\n")
        if not line:
            continue
        try:
            if line == "QUIT":
                try:
                    print("BYE", flush=True)
                except BrokenPipeError:
                    pass
                return 0
            if line == "PING":
                print(f"PONG cpu gpu_child={int(gpu_child)}", flush=True)
                continue
            if not line.startswith("SYNTH "):
                print("ERR unknown command", flush=True)
                continue

            rest = line[6:]
            voice, rest = rest.split(" ", 1)
            speed_s, rest = rest.split(" ", 1)
            out_path, text = rest.split(" ", 1)
            speed = float(speed_s)
            if not text.strip():
                print("ERR empty text", flush=True)
                continue
            speed = max(0.5, min(2.0, speed))

            t1 = time.time()

            if gpu_child:
                import subprocess

                env = os.environ.copy()
                proc = subprocess.run(
                    [
                        self_py,
                        "-u",
                        self_script,
                        "--once",
                        voice,
                        f"{speed:.4f}",
                        out_path,
                        text,
                    ],
                    capture_output=True,
                    text=True,
                    env=env,
                    timeout=180,
                )
                if proc.returncode == 0:
                    for ln in (proc.stdout or "").splitlines():
                        if ln.startswith("OK "):
                            print(ln, flush=True)
                            break
                    else:
                        if os.path.isfile(out_path):
                            ms = int((time.time() - t1) * 1000)
                            print(f"OK {out_path} {ms}ms", flush=True)
                        else:
                            print("ERR gpu child produced no wav", flush=True)
                    continue
                err = (proc.stderr or proc.stdout or "gpu child failed").strip().splitlines()
                print(
                    f"gpu child failed ({err[-1] if err else '?'}); CPU fallback",
                    file=sys.stderr,
                    flush=True,
                )

            _synth(pipe, text, voice, speed, out_path, np, sf, torch)
            ms = int((time.time() - t1) * 1000)
            print(f"OK {out_path} {ms}ms", flush=True)
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            msg = str(e).replace("\n", " ").strip() or type(e).__name__
            print(f"ERR {msg}", flush=True)
    return 0


def _synth(pipe, text, voice, speed, out_path, np, sf, torch) -> None:
    chunks: list = []
    with torch.inference_mode():
        for _g, _p, audio in pipe(text, voice=voice, speed=speed):
            if audio is None:
                continue
            chunks.append(np.asarray(audio.detach().float().cpu(), dtype=np.float32).reshape(-1))
    if not chunks:
        raise RuntimeError("no audio produced")
    full = np.concatenate(chunks)
    peak = float(np.max(np.abs(full))) if full.size else 0.0
    if peak > 1e-6:
        full = full * min(0.95 / peak, 1.0)
    sf.write(out_path, full, 24000)


def _once_main(argv: list[str]) -> int:
    """Optional one-shot GPU path (FF4_TTS_GPU_CHILD=1)."""
    if len(argv) < 5:
        print("ERR once usage", flush=True)
        return 2
    voice, speed_s, out_path = argv[1], argv[2], argv[3]
    text = " ".join(argv[4:])
    speed = max(0.5, min(2.0, float(speed_s)))

    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    os.environ.setdefault("MIOPEN_FIND_MODE", "FAST")

    import numpy as np
    import soundfile as sf
    import torch
    from kokoro import KPipeline

    if not torch.cuda.is_available():
        print("ERR no cuda", flush=True)
        return 1

    t0 = time.time()
    pipe = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M", device="cuda")
    chunks: list = []
    with torch.inference_mode():
        for _g, _p, audio in pipe(text, voice=voice, speed=speed):
            if audio is None:
                continue
            chunks.append(np.asarray(audio.detach().float().cpu(), dtype=np.float32).reshape(-1))
    if not chunks:
        print("ERR no audio", flush=True)
        return 1
    full = np.concatenate(chunks)
    peak = float(np.max(np.abs(full))) if full.size else 0.0
    if peak > 1e-6:
        full = full * min(0.95 / peak, 1.0)
    sf.write(out_path, full, 24000)
    print(f"OK {out_path} {int((time.time() - t0) * 1000)}ms", flush=True)
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--once":
        raise SystemExit(_once_main(sys.argv[1:]))
    raise SystemExit(main())
