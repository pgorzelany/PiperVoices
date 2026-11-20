#include "EnclavePiperNative.h"
#include "piper.h"

// Piper and ONNX Runtime can throw when parsing config or executing a graph.
// Translate native exceptions before crossing the Swift/C boundary.
EnclavePiperModel *enclave_piper_create(const char *model, const char *config,
                                        const char *espeak_data) {
  try {
    return piper_create(model, config, espeak_data);
  } catch (...) {
    return nullptr;
  }
}

void enclave_piper_free(EnclavePiperModel *model) { piper_free(model); }

int enclave_piper_start(EnclavePiperModel *model, const char *text) {
  try {
    return piper_synthesize_start(model, text, nullptr);
  } catch (...) {
    return PIPER_ERR_GENERIC;
  }
}

int enclave_piper_next(EnclavePiperModel *model, EnclavePiperWindow *window) {
  *window = {};
  try {
    piper_audio_chunk chunk{};
    const auto result = piper_synthesize_next(model, &chunk);
    if (result != PIPER_OK && result != PIPER_DONE) {
      return PIPER_ERR_GENERIC;
    }
    window->samples = chunk.samples;
    window->frame_count = chunk.num_samples;
    window->sample_rate = chunk.sample_rate;
    return result == PIPER_DONE ? ENCLAVE_PIPER_DONE : ENCLAVE_PIPER_OK;
  } catch (...) {
    return PIPER_ERR_GENERIC;
  }
}
