#include <jni.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "whisper.h"

namespace {
std::mutex g_mutex;
whisper_context * g_ctx = nullptr;

std::string trim_copy(const std::string & s) {
    size_t start = 0;
    while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) {
        ++start;
    }

    size_t end = s.size();
    while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1]))) {
        --end;
    }

    return s.substr(start, end - start);
}
} // namespace

extern "C"
JNIEXPORT jboolean JNICALL
Java_com_example_offline_1stt_1demo_WhisperNative_initContext(
        JNIEnv * env,
        jclass /*clazz*/,
        jstring modelPath,
        jint /*threads*/) {
    std::lock_guard<std::mutex> lock(g_mutex);

    if (g_ctx != nullptr) {
        whisper_free(g_ctx);
        g_ctx = nullptr;
    }

    const char * model_path_c = env->GetStringUTFChars(modelPath, nullptr);
    if (model_path_c == nullptr) {
        return JNI_FALSE;
    }

    whisper_context_params cparams = whisper_context_default_params();
    g_ctx = whisper_init_from_file_with_params(model_path_c, cparams);

    env->ReleaseStringUTFChars(modelPath, model_path_c);

    return g_ctx != nullptr ? JNI_TRUE : JNI_FALSE;
}

extern "C"
JNIEXPORT void JNICALL
Java_com_example_offline_1stt_1demo_WhisperNative_freeContext(
        JNIEnv * /*env*/,
        jclass /*clazz*/) {
    std::lock_guard<std::mutex> lock(g_mutex);

    if (g_ctx != nullptr) {
        whisper_free(g_ctx);
        g_ctx = nullptr;
    }
}

extern "C"
JNIEXPORT jstring JNICALL
Java_com_example_offline_1stt_1demo_WhisperNative_transcribeWindow(
        JNIEnv * env,
        jclass /*clazz*/,
        jfloatArray audio,
        jstring language,
        jint audioCtx) {
    std::lock_guard<std::mutex> lock(g_mutex);

    if (g_ctx == nullptr) {
        return env->NewStringUTF("");
    }

    const jsize n = env->GetArrayLength(audio);
    if (n <= 0) {
        return env->NewStringUTF("");
    }

    jfloat * audio_ptr = env->GetFloatArrayElements(audio, nullptr);
    if (audio_ptr == nullptr) {
        return env->NewStringUTF("");
    }

    std::vector<float> pcm(audio_ptr, audio_ptr + n);
    env->ReleaseFloatArrayElements(audio, audio_ptr, JNI_ABORT);

    const char * lang_c = env->GetStringUTFChars(language, nullptr);
    const char * language_to_use =
            (lang_c != nullptr && std::strlen(lang_c) > 0) ? lang_c : "en";

    whisper_full_params params =
            whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;

    params.translate = false;
    params.no_context = true;
    params.no_timestamps = true;
    params.single_segment = true;

    params.max_tokens = 32;
    params.audio_ctx = static_cast<int>(audioCtx);
    params.language = language_to_use;

    params.temperature = 0.0f;
    params.greedy.best_of = 1;

    if (whisper_full(g_ctx, params, pcm.data(), static_cast<int>(pcm.size())) != 0) {
        if (lang_c != nullptr) {
            env->ReleaseStringUTFChars(language, lang_c);
        }
        return env->NewStringUTF("");
    }

    std::string text;
    const int n_segments = whisper_full_n_segments(g_ctx);
    for (int i = 0; i < n_segments; ++i) {
        const char * seg = whisper_full_get_segment_text(g_ctx, i);
        if (seg != nullptr) {
            text += seg;
        }
    }

    if (lang_c != nullptr) {
        env->ReleaseStringUTFChars(language, lang_c);
    }

    text = trim_copy(text);
    return env->NewStringUTF(text.c_str());
}