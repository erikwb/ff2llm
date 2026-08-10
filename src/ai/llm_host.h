//! In-process Gemma (libllama) — no daemon, model stays warm after load.
#ifndef FF4_LLM_HOST_H
#define FF4_LLM_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Ff4Llm Ff4Llm;

/** Progress 0..1 during load; return 0 to abort, 1 to continue. */
typedef int (*Ff4LlmProgressFn)(float progress, const char* stage, void* user);

/**
 * Load GGUF with full GPU offload when ROCm/Vulkan available.
 * `progress` may be NULL. Blocks until model + context ready (+ optional warmup).
 */
Ff4Llm* ff4_llm_create(const char* model_path, Ff4LlmProgressFn progress, void* user);

void ff4_llm_destroy(Ff4Llm* llm);

/** True if create succeeded and GPU layers were requested. */
int ff4_llm_ok(const Ff4Llm* llm);

/**
 * Generate a short reply. Clears KV cache each call (stateless turns).
 * Writes NUL-terminated UTF-8 into `out` (capacity `out_cap`).
 * Returns bytes written (excluding NUL), or -1 on error.
 */
int ff4_llm_generate(
    Ff4Llm* llm,
    const char* system_prompt,
    const char* user_prompt,
    char* out,
    int out_cap,
    int max_tokens);

/** Human-readable backend info (static buffer, not thread-safe). */
const char* ff4_llm_backend_info(const Ff4Llm* llm);

#ifdef __cplusplus
}
#endif

#endif
