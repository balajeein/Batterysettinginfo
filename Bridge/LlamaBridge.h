#ifndef LLAMA_BRIDGE_H
#define LLAMA_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to the native llama.cpp engine instance
typedef struct LlamaEngine LlamaEngine;

/// Initialize backend and load GGUF model into memory.
/// Returns NULL on failure.
/// n_ctx: context size (e.g. 2048, or <= 0 for default 2048)
/// n_threads: CPU threads to use (e.g. 4, or <= 0 for hardware concurrency)
/// n_gpu_layers: GPU layers to offload to Metal (e.g. 99 for full Metal acceleration)
LlamaEngine* llama_engine_create(
    const char* model_path,
    int n_ctx,
    int n_threads,
    int n_gpu_layers
);

/// Release the model and inference context, freeing memory.
void llama_engine_destroy(LlamaEngine* engine);

/// Validate whether the given file path exists and is a valid GGUF file.
bool llama_engine_is_valid_gguf(const char* model_path);

/// Return a string describing the active backend (e.g. "Metal (Apple Silicon)").
const char* llama_engine_get_backend_info(void);

/// Run local inference on the supplied prompt.
/// Writes null-terminated generated text into output_buf.
/// Returns number of characters written, or negative on failure:
///   -1: invalid engine or parameters
///   -2: failed to tokenize prompt
///   -3: failed to create context or sampler
///   -4: inference decode failure
int llama_engine_infer(
    LlamaEngine* engine,
    const char* prompt,
    char* output_buf,
    int max_output_len,
    int max_tokens,
    float temperature
);

#ifdef __cplusplus
}
#endif

#endif // LLAMA_BRIDGE_H
