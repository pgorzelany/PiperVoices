#ifndef ENCLAVE_PIPER_NATIVE_H
#define ENCLAVE_PIPER_NATIVE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct piper_synthesizer EnclavePiperModel;

typedef struct {
    const float *samples;
    size_t frame_count;
    int sample_rate;
} EnclavePiperWindow;

#define ENCLAVE_PIPER_OK 0
#define ENCLAVE_PIPER_DONE 1

EnclavePiperModel *enclave_piper_create(const char *model, const char *config, const char *espeak_data);
void enclave_piper_free(EnclavePiperModel *model);
int enclave_piper_start(EnclavePiperModel *model, const char *text);
int enclave_piper_next(EnclavePiperModel *model, EnclavePiperWindow *window);
void enclave_piper_reset(EnclavePiperModel *model);

#ifdef __cplusplus
}
#endif

#endif
