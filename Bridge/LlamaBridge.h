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

/// Load mmproj vision projector into engine.
/// Returns true on success, false on failure.
bool llama_engine_load_mmproj(
    LlamaEngine* engine,
    const char* mmproj_path
);

/// Checks if mmproj vision model is loaded and ready
bool llama_engine_has_vision(LlamaEngine* engine);

/// Run multimodal vision inference on an in-memory RGB pixel buffer.
/// rgb_bytes: raw RGB pixel bytes (width * height * 3)
/// width, height: pixel dimensions of the image
/// prompt: user instruction / text prompt
/// output_buf: buffer to receive output string
/// max_output_len: size of output_buf
/// max_tokens: maximum tokens to generate
/// temperature: sampling temperature
/// Returns number of characters written, or negative on failure:
///   -1: invalid engine or parameters
///   -2: vision projector not loaded
///   -3: bitmap or tokenization failure
///   -4: context eval failure
///   -5: decode failure
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
);

#ifdef __cplusplus
}
#endif

#endif // LLAMA_BRIDGE_H
