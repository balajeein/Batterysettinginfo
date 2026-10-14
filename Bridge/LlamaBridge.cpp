#include "LlamaBridge.h"
#include "llama.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <mutex>
#include <thread>

struct LlamaEngine {
    llama_model* model = nullptr;
    const llama_vocab* vocab = nullptr;
    int n_ctx = 2048;
    int n_threads = 4;
    int n_gpu_layers = 99;
    std::mutex mtx;
};

static void batch_set_tokens(llama_batch_ext * batch, const llama_token * tokens, int32_t n_tokens, llama_pos pos_0) {
    llama_batch_ext_clear(batch);
    for (int32_t i = 0; i < n_tokens; ++i) {
        const int32_t idx = llama_batch_ext_add_token(batch, 0, tokens[i]);
        const llama_pos pos = pos_0 + i;
        llama_batch_ext_set_pos(batch, idx, &pos);
    }
    llama_batch_ext_set_output_logits(batch, n_tokens - 1, true);
}

bool llama_engine_is_valid_gguf(const char* model_path) {
    if (!model_path || strlen(model_path) == 0) {
        return false;
    }
    FILE* f = fopen(model_path, "rb");
    if (!f) {
        return false;
    }
    char magic[4] = {0};
    size_t read_bytes = fread(magic, 1, 4, f);
    fclose(f);
    if (read_bytes != 4) {
        return false;
    }
    return (magic[0] == 'G' && magic[1] == 'G' && magic[2] == 'U' && magic[3] == 'F');
}

const char* llama_engine_get_backend_info(void) {
#if defined(GGML_USE_METAL)
    return "llama.cpp (Apple Silicon Metal)";
#else
    return "llama.cpp (CPU Backend)";
#endif
}

LlamaEngine* llama_engine_create(
    const char* model_path,
    int n_ctx,
    int n_threads,
    int n_gpu_layers
) {
    if (!model_path || !llama_engine_is_valid_gguf(model_path)) {
        fprintf(stderr, "[LlamaBridge] Invalid model file or GGUF signature: %s\n", model_path ? model_path : "NULL");
        return nullptr;
    }

    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = (n_gpu_layers >= 0) ? n_gpu_layers : 99;

    llama_model* model = llama_model_load_from_file(model_path, mparams);
    if (!model) {
        fprintf(stderr, "[LlamaBridge] Failed to load model from %s\n", model_path);
        return nullptr;
    }

    const llama_vocab* vocab = llama_model_get_vocab(model);
    if (!vocab) {
        fprintf(stderr, "[LlamaBridge] Failed to extract vocab from model\n");
        llama_model_free(model);
        return nullptr;
    }

    LlamaEngine* engine = new LlamaEngine();
    engine->model = model;
    engine->vocab = vocab;
    engine->n_ctx = (n_ctx > 256) ? n_ctx : 2048;

    if (n_threads > 0) {
        engine->n_threads = n_threads;
    } else {
        unsigned int hw = std::thread::hardware_concurrency();
        engine->n_threads = (hw > 0) ? (int)hw : 4;
    }
    engine->n_gpu_layers = mparams.n_gpu_layers;

    return engine;
}

void llama_engine_destroy(LlamaEngine* engine) {
    if (!engine) return;
    std::lock_guard<std::mutex> lock(engine->mtx);
    if (engine->model) {
        llama_model_free(engine->model);
        engine->model = nullptr;
    }
    delete engine;
}

int llama_engine_infer(
    LlamaEngine* engine,
    const char* prompt,
    char* output_buf,
    int max_output_len,
    int max_tokens,
    float temperature
) {
    if (!engine || !engine->model || !prompt || !output_buf || max_output_len <= 1) {
        return -1;
    }

    std::lock_guard<std::mutex> lock(engine->mtx);

    // 1. Tokenize prompt
    const int prompt_len = (int)strlen(prompt);
    const int n_prompt = -llama_tokenize(engine->vocab, prompt, prompt_len, NULL, 0, true, true);
    if (n_prompt <= 0) {
        fprintf(stderr, "[LlamaBridge] Failed to calculate prompt tokens\n");
        return -2;
    }

    std::vector<llama_token> prompt_tokens(n_prompt);
    if (llama_tokenize(engine->vocab, prompt, prompt_len, prompt_tokens.data(), prompt_tokens.size(), true, true) < 0) {
        fprintf(stderr, "[LlamaBridge] Failed to tokenize prompt\n");
        return -2;
    }

    // 2. Setup context
    int n_predict = (max_tokens > 0) ? max_tokens : 64;
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = n_prompt + n_predict + 64;
    if (ctx_params.n_ctx < (uint32_t)engine->n_ctx) {
        ctx_params.n_ctx = (uint32_t)engine->n_ctx;
    }
    ctx_params.n_batch = n_prompt > 512 ? n_prompt : 512;
    ctx_params.n_threads = engine->n_threads;
    ctx_params.no_perf = true;

    llama_context* ctx = llama_init_from_model(engine->model, ctx_params);
    if (!ctx) {
        fprintf(stderr, "[LlamaBridge] Failed to create llama_context\n");
        return -3;
    }

    // 3. Setup sampler
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    sparams.no_perf = true;
    llama_sampler* smpl = llama_sampler_chain_init(sparams);
    if (temperature <= 0.05f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
    }

    // 4. Batch setup for prompt
    llama_batch_ext* batch = llama_batch_ext_init(ctx);
    batch_set_tokens(batch, prompt_tokens.data(), n_prompt, 0);

    if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)) {
        fprintf(stderr, "[LlamaBridge] Initial prompt evaluation failed\n");
        llama_batch_ext_free(batch);
        llama_sampler_free(smpl);
        llama_free(ctx);
        return -4;
    }

    // 5. Sampling loop
    std::string result_text;
    int n_tokens = 1;
    int n_pos = n_prompt;
    int n_decoded = 0;

    while (n_decoded < n_predict && (int)result_text.size() < (max_output_len - 10)) {
        llama_token new_token = llama_sampler_sample(smpl, ctx, -1);
        llama_sampler_accept(smpl, new_token);

        if (llama_vocab_is_eog(engine->vocab, new_token)) {
            break;
        }

        char piece_buf[64] = {0};
        int piece_len = llama_token_to_piece(engine->vocab, new_token, piece_buf, sizeof(piece_buf), 0, false);
        if (piece_len > 0) {
            result_text.append(piece_buf, piece_len);
        }

        // Prepare next batch with new token
        batch_set_tokens(batch, &new_token, 1, n_pos);
        n_pos += 1;
        n_decoded += 1;

        if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)) {
            break;
        }
    }

    // 6. Copy output
    size_t to_copy = result_text.size();
    if ((int)to_copy >= max_output_len) {
        to_copy = max_output_len - 1;
    }
    memcpy(output_buf, result_text.data(), to_copy);
    output_buf[to_copy] = '\0';

    // 7. Immediate memory cleanup of inference context & batch
    llama_batch_ext_free(batch);
    llama_sampler_free(smpl);
    llama_free(ctx);

    return (int)to_copy;
}
