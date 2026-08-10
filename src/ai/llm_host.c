//! In-process llama.cpp host for FF4 NPC chat (Gemma 4 GGUF + ROCm when available).
#include "llm_host.h"

#include "llama.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct Ff4Llm {
    struct llama_model* model;
    struct llama_context* ctx;
    struct llama_sampler* smpl;
    const struct llama_vocab* vocab;
    int n_gpu_layers;
    int n_batch;
    int n_ubatch;
    char info[128];
};

typedef struct {
    Ff4LlmProgressFn user_cb;
    void* user_data;
    float lo;
    float hi;
    const char* stage;
} ProgressCtx;

static bool model_progress_cb(float progress, void* user_data) {
    ProgressCtx* p = (ProgressCtx*)user_data;
    if (!p || !p->user_cb) return true;
    float t = p->lo + progress * (p->hi - p->lo);
    return p->user_cb(t, p->stage ? p->stage : "Loading model", p->user_data) != 0;
}

static void report(ProgressCtx* p, float t, const char* stage) {
    if (p && p->user_cb) p->user_cb(t, stage, p->user_data);
}

Ff4Llm* ff4_llm_create(const char* model_path, Ff4LlmProgressFn progress, void* user) {
    Ff4Llm* llm;
    ProgressCtx pctx = { .user_cb = progress, .user_data = user, .lo = 0.05f, .hi = 0.85f, .stage = "Loading GGUF" };

    if (!model_path || !model_path[0]) return NULL;

    llm = (Ff4Llm*)calloc(1, sizeof(Ff4Llm));
    if (!llm) return NULL;

    report(&pctx, 0.02f, "Init llama backend");
    llama_backend_init();

    {
        struct llama_model_params mparams = llama_model_default_params();
        /* Negative = offload all layers to GPU (ROCm/Vulkan/CUDA as available). */
        mparams.n_gpu_layers = -1;
        mparams.progress_callback = model_progress_cb;
        mparams.progress_callback_user_data = &pctx;

        report(&pctx, 0.05f, "Loading GGUF (GPU)");
        llm->model = llama_model_load_from_file(model_path, mparams);
        if (!llm->model) {
            /* Retry CPU-only if GPU path failed. */
            mparams.n_gpu_layers = 0;
            pctx.stage = "Loading GGUF (CPU)";
            llm->model = llama_model_load_from_file(model_path, mparams);
        }
        if (!llm->model) {
            ff4_llm_destroy(llm);
            return NULL;
        }
        llm->n_gpu_layers = mparams.n_gpu_layers;
        llm->vocab = llama_model_get_vocab(llm->model);
    }

    report(&pctx, 0.88f, "Creating context");
    {
        struct llama_context_params cparams = llama_context_default_params();
        /* Lore-augmented NPC prompts are ~1–2k tokens; need room for gen. */
        cparams.n_ctx = 4096;
        cparams.n_batch = 512;
        cparams.n_ubatch = 512;
        /* Enough threads for prompt on CPU residual; GPU does the heavy layers. */
        cparams.n_threads = 8;
        cparams.n_threads_batch = 8;

        llm->ctx = llama_init_from_model(llm->model, cparams);
        if (!llm->ctx) {
            ff4_llm_destroy(llm);
            return NULL;
        }
        llm->n_batch = (int)llama_n_batch(llm->ctx);
        llm->n_ubatch = (int)llama_n_ubatch(llm->ctx);
        if (llm->n_ubatch < 1) llm->n_ubatch = 512;
        if (llm->n_batch < 1) llm->n_batch = 512;
    }

    report(&pctx, 0.93f, "Init sampler");
    {
        struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
        llm->smpl = llama_sampler_chain_init(sparams);
        /* Cut greeter loops: penalize recent tokens before nucleus sampling. */
        llama_sampler_chain_add(llm->smpl, llama_sampler_init_penalties(
            /*penalty_last_n*/ 96,
            /*penalty_repeat*/ 1.18f,
            /*penalty_freq*/ 0.35f,
            /*penalty_present*/ 0.15f));
        llama_sampler_chain_add(llm->smpl, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(llm->smpl, llama_sampler_init_top_p(0.9f, 1));
        llama_sampler_chain_add(llm->smpl, llama_sampler_init_temp(0.85f));
        llama_sampler_chain_add(llm->smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    }

    /* Warmup: one token decode so ROCm kernels / weights are hot. */
    report(&pctx, 0.96f, "Warming GPU kernels");
    {
        llama_token bos = llama_vocab_bos(llm->vocab);
        if (bos != LLAMA_TOKEN_NULL) {
            struct llama_batch batch = llama_batch_get_one(&bos, 1);
            (void)llama_decode(llm->ctx, batch);
            llama_memory_clear(llama_get_memory(llm->ctx), true);
        }
    }

    snprintf(llm->info, sizeof(llm->info), "libllama n_gpu_layers=%d n_ctx=%u n_batch=%d",
        llm->n_gpu_layers, (unsigned)llama_n_ctx(llm->ctx), llm->n_batch);

    report(&pctx, 1.0f, "Ready");
    return llm;
}

/** Decode `n_tok` prompt tokens in chunks of n_ubatch (llama aborts if batch > ubatch). */
static int decode_prompt(Ff4Llm* llm, const llama_token* tokens, int n_tok) {
    const int chunk = llm->n_ubatch > 0 ? llm->n_ubatch : 512;
    struct llama_batch batch;
    int i;

    if (n_tok <= 0) return -1;

    /* Fast path: whole prompt fits in one ubatch. */
    if (n_tok <= chunk) {
        batch = llama_batch_get_one((llama_token*)tokens, n_tok);
        return llama_decode(llm->ctx, batch) == 0 ? 0 : -1;
    }

    batch = llama_batch_init((uint32_t)chunk, 0, 1);
    if (!batch.token) return -1;

    for (i = 0; i < n_tok; ) {
        int n_eval = n_tok - i;
        int j;
        if (n_eval > chunk) n_eval = chunk;

        batch.n_tokens = 0;
        for (j = 0; j < n_eval; j++) {
            batch.token[batch.n_tokens] = tokens[i + j];
            batch.pos[batch.n_tokens] = i + j;
            batch.n_seq_id[batch.n_tokens] = 1;
            batch.seq_id[batch.n_tokens][0] = 0;
            /* Only need logits on the last prompt token. */
            batch.logits[batch.n_tokens] = (i + j == n_tok - 1) ? 1 : 0;
            batch.n_tokens++;
        }

        if (llama_decode(llm->ctx, batch) != 0) {
            fprintf(stderr, "ff4_llm: decode failed at token %d/%d (chunk %d)\n", i, n_tok, n_eval);
            llama_batch_free(batch);
            return -1;
        }
        i += n_eval;
    }

    llama_batch_free(batch);
    return 0;
}

void ff4_llm_destroy(Ff4Llm* llm) {
    if (!llm) return;
    if (llm->smpl) llama_sampler_free(llm->smpl);
    if (llm->ctx) llama_free(llm->ctx);
    if (llm->model) llama_model_free(llm->model);
    llama_backend_free();
    free(llm);
}

int ff4_llm_ok(const Ff4Llm* llm) {
    return llm && llm->model && llm->ctx && llm->smpl;
}

const char* ff4_llm_backend_info(const Ff4Llm* llm) {
    return llm ? llm->info : "none";
}

/** Build a simple chat prompt; prefer model template, else Gemma-style turns. */
static int build_prompt(Ff4Llm* llm, const char* system_prompt, const char* user_prompt, char* buf, int cap) {
    const char* tmpl = llama_model_chat_template(llm->model, /*name*/ NULL);
    struct llama_chat_message messages[2];
    int n_msg = 0;
    int n;

    if (system_prompt && system_prompt[0]) {
        messages[n_msg].role = "system";
        messages[n_msg].content = system_prompt;
        n_msg++;
    }
    messages[n_msg].role = "user";
    messages[n_msg].content = user_prompt ? user_prompt : "";
    n_msg++;

    if (tmpl && tmpl[0]) {
        n = llama_chat_apply_template(tmpl, messages, (size_t)n_msg, /*add_ass*/ true, buf, cap);
        if (n > 0 && n < cap) return n;
        if (n >= cap) {
            /* Buffer too small — fall through to manual. */
        }
    }

    /* Manual Gemma-style template (no thinking channel). */
    n = snprintf(buf, (size_t)cap,
        "<start_of_turn>user\n%s\n\n%s<end_of_turn>\n<start_of_turn>model\n",
        system_prompt && system_prompt[0] ? system_prompt : "You are a helpful NPC.",
        user_prompt ? user_prompt : "");
    return (n > 0 && n < cap) ? n : -1;
}

int ff4_llm_generate(
    Ff4Llm* llm,
    const char* system_prompt,
    const char* user_prompt,
    char* out,
    int out_cap,
    int max_tokens)
{
    char* prompt = NULL;
    const int prompt_cap = 16384;
    llama_token* tokens = NULL;
    int n_prompt = 0;
    int n_tok = 0;
    int out_len = 0;
    int i;
    int max_ctx;
    int n_gen = 0;

    if (!ff4_llm_ok(llm) || !out || out_cap < 8) return -1;
    if (max_tokens < 1) max_tokens = 64;
    if (max_tokens > 256) max_tokens = 256;

    out[0] = 0;
    llama_memory_clear(llama_get_memory(llm->ctx), true);
    llama_sampler_reset(llm->smpl);

    prompt = (char*)malloc((size_t)prompt_cap);
    if (!prompt) return -1;
    n_prompt = build_prompt(llm, system_prompt, user_prompt, prompt, prompt_cap);
    if (n_prompt <= 0) {
        fprintf(stderr, "ff4_llm: build_prompt failed (sys_len=%zu user_len=%zu)\n",
            system_prompt ? strlen(system_prompt) : 0,
            user_prompt ? strlen(user_prompt) : 0);
        free(prompt);
        return -1;
    }

    /* Tokenize (add special tokens as template usually includes them). */
    max_ctx = (int)llama_n_ctx(llm->ctx);
    tokens = (llama_token*)malloc(sizeof(llama_token) * (size_t)max_ctx);
    if (!tokens) {
        free(prompt);
        return -1;
    }

    n_tok = llama_tokenize(llm->vocab, prompt, n_prompt, tokens, max_ctx, /*add_special*/ true, /*parse_special*/ true);
    free(prompt);
    prompt = NULL;
    if (n_tok < 0) {
        /* Negative = would need -n_tok slots */
        fprintf(stderr, "ff4_llm: tokenize needed %d tokens (ctx=%d)\n", -n_tok, max_ctx);
        free(tokens);
        return -1;
    }
    if (n_tok >= max_ctx - max_tokens) {
        fprintf(stderr, "ff4_llm: prompt too long n_tok=%d ctx=%d max_gen=%d\n", n_tok, max_ctx, max_tokens);
        free(tokens);
        return -1;
    }

    fprintf(stderr, "ff4_llm: prefill n_tok=%d n_ubatch=%d\n", n_tok, llm->n_ubatch);

    /* Prefill in ubatch-sized chunks — full-prompt decode aborts if n_tok > n_ubatch. */
    if (decode_prompt(llm, tokens, n_tok) != 0) {
        free(tokens);
        return -1;
    }

    /* Generate */
    for (n_gen = 0; n_gen < max_tokens; n_gen++) {
        llama_token id = llama_sampler_sample(llm->smpl, llm->ctx, -1);
        if (llama_vocab_is_eog(llm->vocab, id)) break;

        {
            char piece[256];
            int np = llama_token_to_piece(llm->vocab, id, piece, (int)sizeof(piece), 0, /*special*/ false);
            if (np > 0) {
                if (out_len + np >= out_cap - 1) break;
                memcpy(out + out_len, piece, (size_t)np);
                out_len += np;
                out[out_len] = 0;
            }
        }

        {
            struct llama_batch batch = llama_batch_get_one(&id, 1);
            if (llama_decode(llm->ctx, batch) != 0) break;
        }
    }

    free(tokens);

    /* Strip accidental quotes / whitespace */
    while (out_len > 0 && (out[out_len - 1] == ' ' || out[out_len - 1] == '\n' || out[out_len - 1] == '\r')) {
        out[--out_len] = 0;
    }
    if (out_len >= 2 && out[0] == '"' && out[out_len - 1] == '"') {
        memmove(out, out + 1, (size_t)(out_len - 2));
        out_len -= 2;
        out[out_len] = 0;
    }

    /* Drop leading "model" thinking-ish prefixes if any slipped through */
    {
        static const char* junk[] = { "Thinking Process:", "Thinking:", "**Analyze", NULL };
        for (i = 0; junk[i]; i++) {
            if (strncmp(out, junk[i], strlen(junk[i])) == 0) {
                /* Prefer last non-empty line as the spoken line */
                char* last = strrchr(out, '\n');
                if (last && last[1]) {
                    char* line = last + 1;
                    while (*line == ' ') line++;
                    memmove(out, line, strlen(line) + 1);
                    out_len = (int)strlen(out);
                }
                break;
            }
        }
    }

    return out_len;
}
