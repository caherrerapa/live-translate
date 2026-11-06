/* Thin cache-aware streaming wrapper around sherpa-onnx.
 * Audio stays in the caller. This file does not open a capture device or a socket.
 */
#include <sherpa-onnx/c-api/c-api.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct LTStream {
    const SherpaOnnxOnlineRecognizer *recognizer;
    const SherpaOnnxOnlineStream *stream;
    char *encoder;
    char *decoder;
    char *joiner;
    char *tokens;
    char *language;
    char *provider;
    char *method;
} LTStream;

void lt_close(LTStream *handle);
void lt_reset(LTStream *handle);

static char *lt_dup(const char *text) {
    if (!text) {
        return NULL;
    }
    size_t n = strlen(text) + 1;
    char *copy = malloc(n);
    if (copy) {
        memcpy(copy, text, n);
    }
    return copy;
}

LTStream *lt_open_ex(
    const char *encoder,
    const char *decoder,
    const char *joiner,
    const char *tokens,
    const char *language,
    int32_t feature_dim,
    int32_t num_threads
) {
    LTStream *handle = calloc(1, sizeof(*handle));
    if (!handle) {
        return NULL;
    }
    handle->encoder = lt_dup(encoder);
    handle->decoder = lt_dup(decoder);
    handle->joiner = lt_dup(joiner);
    handle->tokens = lt_dup(tokens);
    handle->language = lt_dup(language ? language : "");
    handle->provider = lt_dup("cpu");
    handle->method = lt_dup("greedy_search");
    if (!handle->encoder || !handle->decoder || !handle->joiner || !handle->tokens || !handle->language) {
        lt_close(handle);
        return NULL;
    }

    SherpaOnnxOnlineRecognizerConfig config;
    memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    /* NeMo FastConformer graphs take 128 mel bins. sherpa Zipformer graphs take 80. */
    config.feat_config.feature_dim = feature_dim > 0 ? feature_dim : 128;
    config.model_config.transducer.encoder = handle->encoder;
    config.model_config.transducer.decoder = handle->decoder;
    config.model_config.transducer.joiner = handle->joiner;
    config.model_config.tokens = handle->tokens;
    config.model_config.num_threads = num_threads > 0 ? num_threads : 4;
    config.model_config.provider = handle->provider;
    config.decoding_method = handle->method;
    config.enable_endpoint = 1;
    config.rule1_min_trailing_silence = 2.4f;
    config.rule2_min_trailing_silence = 1.2f;
    config.rule3_min_utterance_length = 20.f;

    handle->recognizer = SherpaOnnxCreateOnlineRecognizer(&config);
    if (!handle->recognizer) {
        lt_close(handle);
        return NULL;
    }
    handle->stream = SherpaOnnxCreateOnlineStream(handle->recognizer);
    if (!handle->stream) {
        lt_close(handle);
        return NULL;
    }
    SherpaOnnxOnlineStreamSetOption(handle->stream, "language", handle->language);
    return handle;
}

LTStream *lt_open(
    const char *encoder,
    const char *decoder,
    const char *joiner,
    const char *tokens,
    const char *language
) {
    return lt_open_ex(encoder, decoder, joiner, tokens, language, 128, 4);
}

/* Starts a new utterance on a loaded recognizer. The weights stay resident. */
void lt_reset(LTStream *handle) {
    if (!handle) {
        return;
    }
    SherpaOnnxOnlineStreamReset(handle->recognizer, handle->stream);
    if (handle->language && handle->language[0]) {
        SherpaOnnxOnlineStreamSetOption(handle->stream, "language", handle->language);
    }
}

int lt_push(
    LTStream *handle,
    const float *samples,
    int32_t count,
    char *out,
    int32_t capacity,
    int32_t *endpoint
) {
    if (!handle || !out || capacity < 1) {
        return -1;
    }
    out[0] = '\0';
    if (endpoint) {
        *endpoint = 0;
    }
    if (count > 0 && samples) {
        SherpaOnnxOnlineStreamAcceptWaveform(handle->stream, 16000, samples, count);
    }
    while (SherpaOnnxIsOnlineStreamReady(handle->recognizer, handle->stream)) {
        SherpaOnnxDecodeOnlineStream(handle->recognizer, handle->stream);
    }
    const SherpaOnnxOnlineRecognizerResult *result =
        SherpaOnnxGetOnlineStreamResult(handle->recognizer, handle->stream);
    if (result && result->text) {
        strncpy(out, result->text, (size_t)capacity - 1);
        out[capacity - 1] = '\0';
    }
    int at_endpoint = SherpaOnnxOnlineStreamIsEndpoint(handle->recognizer, handle->stream);
    if (result) {
        SherpaOnnxDestroyOnlineRecognizerResult(result);
    }
    if (at_endpoint) {
        if (endpoint) {
            *endpoint = 1;
        }
        lt_reset(handle);
    }
    return 0;
}

void lt_close(LTStream *handle) {
    if (!handle) {
        return;
    }
    if (handle->stream) {
        SherpaOnnxDestroyOnlineStream(handle->stream);
    }
    if (handle->recognizer) {
        SherpaOnnxDestroyOnlineRecognizer(handle->recognizer);
    }
    free(handle->encoder);
    free(handle->decoder);
    free(handle->joiner);
    free(handle->tokens);
    free(handle->language);
    free(handle->provider);
    free(handle->method);
    free(handle);
}
