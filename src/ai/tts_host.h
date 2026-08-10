//! Kokoro TTS via long-lived PyTorch ROCm worker (no MIGraphX/ORT).
#ifndef FF4_TTS_HOST_H
#define FF4_TTS_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Ff4Tts Ff4Tts;

/**
 * Start the ROCm Kokoro worker and wait until READY.
 * `model_dir` is ignored (HF cache / worker owns weights); may be NULL.
 * Returns NULL on failure (missing venv/worker, no GPU, spawn error).
 */
Ff4Tts* ff4_tts_create(const char* model_dir);

void ff4_tts_destroy(Ff4Tts* tts);

int ff4_tts_ok(const Ff4Tts* tts);

/** Kokoro-82M English voices (0–10). */
int ff4_tts_num_speakers(const Ff4Tts* tts);

/** 24000 for Kokoro. */
int ff4_tts_sample_rate(const Ff4Tts* tts);

/**
 * Synthesize `text` with speaker id `sid` (0–10) and write mono 16-bit WAV.
 * `speed` > 1 faster; < 1 slower. Returns 0 on success, -1 on error.
 */
int ff4_tts_synthesize(
    Ff4Tts* tts,
    const char* text,
    int sid,
    float speed,
    const char* out_wav);

const char* ff4_tts_info(const Ff4Tts* tts);

#ifdef __cplusplus
}
#endif

#endif
