#include "LlamaBridge.h"
#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"
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
    mtmd_context* ctx_vision = nullptr;
    std::string loaded_mmproj_path;
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
    if (engine->ctx_vision) {
        mtmd_free(engine->ctx_vision);
        engine->ctx_vision = nullptr;
    }
    if (engine->model) {
        llama_model_free(engine->model);
        engine->model = nullptr;
    }
    delete engine;
}

bool llama_engine_load_mmproj(LlamaEngine* engine, const char* mmproj_path) {
    if (!engine || !engine->model || !mmproj_path || strlen(mmproj_path) == 0) {
        return false;
    }
    std::lock_guard<std::mutex> lock(engine->mtx);

    if (engine->ctx_vision) {
        if (engine->loaded_mmproj_path == mmproj_path) {
            return true;
        }
        mtmd_free(engine->ctx_vision);
        engine->ctx_vision = nullptr;
        engine->loaded_mmproj_path.clear();
    }

    if (!llama_engine_is_valid_gguf(mmproj_path)) {
        fprintf(stderr, "[LlamaBridge] Invalid mmproj GGUF file: %s\n", mmproj_path);
        return false;
    }

    mtmd_context_params mparams = mtmd_context_params_default();
    mparams.use_gpu = (engine->n_gpu_layers > 0);
    mparams.n_threads = engine->n_threads;
    mparams.print_timings = false;

    mtmd_context* vctx = mtmd_init_from_file(mmproj_path, engine->model, mparams);
    if (!vctx) {
        fprintf(stderr, "[LlamaBridge] Failed to load mmproj projector from %s\n", mmproj_path);
        return false;
    }

    engine->ctx_vision = vctx;
    engine->loaded_mmproj_path = mmproj_path;
    fprintf(stderr, "[LlamaBridge] Multimodal projector successfully loaded from %s\n", mmproj_path);
    return true;
}

bool llama_engine_has_vision(LlamaEngine* engine) {
    if (!engine) return false;
    std::lock_guard<std::mutex> lock(engine->mtx);
    return (engine->ctx_vision != nullptr && mtmd_support_vision(engine->ctx_vision));
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

int llama_engine_infer_vision(
    LlamaEngine* engine,
    const unsigned char* rgb_bytes,
    int width,
    int height,
    const char* prompt,
    char* output_buf,
    int max_output_len,
    int max_tokens,
    float temperature
) {
    if (!engine || !engine->model || !rgb_bytes || width <= 0 || height <= 0 || !prompt || !output_buf || max_output_len <= 1) {
        fprintf(stderr, "[LlamaBridge] Invalid arguments passed to llama_engine_infer_vision\n");
        return -1;
    }

    std::lock_guard<std::mutex> lock(engine->mtx);

    if (!engine->ctx_vision || !mtmd_support_vision(engine->ctx_vision)) {
        fprintf(stderr, "[LlamaBridge] Multimodal context not initialized or vision not supported\n");
        return -2;
    }

    // Format prompt with media marker
    const char* marker = mtmd_get_marker(engine->ctx_vision);
    if (!marker) {
        marker = mtmd_default_marker();
    }

    std::string full_prompt;
    if (strstr(prompt, marker) != nullptr) {
        full_prompt = prompt;
    } else if (strstr(prompt, "<|im_start|>") != nullptr) {
        std::string p(prompt);
        size_t pos = p.find("<|im_start|>user\n");
        if (pos != std::string::npos) {
            pos += strlen("<|im_start|>user\n");
            p.insert(pos, std::string(marker) + "\n");
            full_prompt = p;
        } else {
            full_prompt = std::string(marker) + "\n" + p;
        }
    } else {
        full_prompt = std::string("<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\n")
                    + marker + "\n" + prompt + "<|im_end|>\n<|im_start|>assistant\n";
    }

    // 1. Create in-memory bitmap
    mtmd_bitmap* bmp = mtmd_bitmap_init((uint32_t)width, (uint32_t)height, rgb_bytes);
    if (!bmp) {
        fprintf(stderr, "[LlamaBridge] Failed to create mtmd_bitmap (%dx%d)\n", width, height);
        return -3;
    }

    // 2. Tokenize prompt & image
    mtmd_input_text text_input;
    text_input.text = full_prompt.c_str();
    text_input.text_len = full_prompt.length();
    text_input.add_special = true;
    text_input.parse_special = true;

    const mtmd_bitmap* bmps[1] = { bmp };
    mtmd_input_chunks* chunks = mtmd_input_chunks_init();
    int32_t tok_res = mtmd_tokenize(engine->ctx_vision, chunks, &text_input, bmps, 1);
    mtmd_bitmap_free(bmp); // mtmd_tokenize has copied/preprocessed data into chunks

    if (tok_res != 0) {
        fprintf(stderr, "[LlamaBridge] mtmd_tokenize failed with code %d\n", tok_res);
        mtmd_input_chunks_free(chunks);
        return -3;
    }

    llama_pos n_pos_prompt = mtmd_helper_get_n_pos(chunks);
    int n_predict = (max_tokens > 0) ? max_tokens : 128;
    uint32_t needed_ctx = (uint32_t)n_pos_prompt + (uint32_t)n_predict + 64;
    if (needed_ctx < 2048) {
        needed_ctx = 2048;
    }

    // 3. Setup context with sufficient batch capacity for visual tokens
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = needed_ctx;
    ctx_params.n_batch = 2048;
    ctx_params.n_ubatch = 2048;
    ctx_params.n_threads = engine->n_threads;
    ctx_params.no_perf = true;

    llama_context* ctx = llama_init_from_model(engine->model, ctx_params);
    if (!ctx) {
        fprintf(stderr, "[LlamaBridge] Failed to create vision llama_context (n_ctx=%u)\n", needed_ctx);
        mtmd_input_chunks_free(chunks);
        return -3;
    }

    // 4. Setup sampler
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    sparams.no_perf = true;
    llama_sampler* smpl = llama_sampler_chain_init(sparams);
    if (temperature <= 0.05f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
    }

    // 5. Evaluate all chunks (text + vision embeddings)
    llama_pos n_past = 0;
    int32_t eval_res = mtmd_helper_eval_chunks(
        engine->ctx_vision,
        ctx,
        chunks,
        0, // n_past
        0, // seq_id
        ctx_params.n_batch,
        true, // logits_last
        &n_past
    );
    mtmd_input_chunks_free(chunks);

    if (eval_res != 0) {
        fprintf(stderr, "[LlamaBridge] mtmd_helper_eval_chunks failed with code %d\n", eval_res);
        llama_sampler_free(smpl);
        llama_free(ctx);
        return -4;
    }

    // 6. Autoregressive token generation
    llama_batch_ext* batch = llama_batch_ext_init(ctx);
    std::string result_text;
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

        batch_set_tokens(batch, &new_token, 1, n_past);
        n_past += 1;
        n_decoded += 1;

        if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch)) {
            fprintf(stderr, "[LlamaBridge] Decode error during generation at token %d\n", n_decoded);
            break;
        }
    }

    // 7. Output result
    size_t to_copy = result_text.size();
    if ((int)to_copy >= max_output_len) {
        to_copy = max_output_len - 1;
    }
    memcpy(output_buf, result_text.data(), to_copy);
    output_buf[to_copy] = '\0';

    // 8. Clean up
    llama_batch_ext_free(batch);
    llama_sampler_free(smpl);
    llama_free(ctx);

    return (int)to_copy;
}
