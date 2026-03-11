#include <jni.h>
#include <android/log.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "whisper.h"

#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, "whisper_jni", __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  "whisper_jni", __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  "whisper_jni", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "whisper_jni", __VA_ARGS__)

static whisper_context *g_ctx = nullptr;

static std::mutex g_ctx_mu;
static std::mutex g_audio_mu;

static const int kSampleRate = 16000;
static const int kKeepSeconds = 20;
static const int kKeepSamples = kKeepSeconds * kSampleRate;

static const bool kReturnDebugStatusWhenEmpty = true;

static std::vector<float> g_audio;
static size_t g_start = 0;
static int64_t g_base_sample = 0;

struct ScopeTimer {
    const char *name;
    std::chrono::steady_clock::time_point start;

    explicit ScopeTimer(const char *n)
        : name(n), start(std::chrono::steady_clock::now()) {}

    ~ScopeTimer() {
        const auto end = std::chrono::steady_clock::now();
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
        LOGI("%s took %lld ms", name, (long long) ms);
    }
};

static inline void ltrim(std::string &s) {
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), [](unsigned char ch) {
        return !std::isspace(ch);
    }));
}

static inline void rtrim(std::string &s) {
    s.erase(std::find_if(s.rbegin(), s.rend(), [](unsigned char ch) {
        return !std::isspace(ch);
    }).base(), s.end());
}

static inline void trim(std::string &s) {
    ltrim(s);
    rtrim(s);
}

static std::string strip_special_tokens(std::string s) {
    const char *toks[] = {"[BLANK_AUDIO]", "[MUSIC]", "[NOISE]"};
    for (auto t : toks) {
        for (;;) {
            auto pos = s.find(t);
            if (pos == std::string::npos) break;
            s.erase(pos, std::strlen(t));
        }
    }
    return s;
}

static inline size_t live_size_locked() {
    return (g_audio.size() > g_start) ? (g_audio.size() - g_start) : 0;
}

static inline void compact_if_needed_locked() {
    const size_t threshold = (size_t) 5 * (size_t) kSampleRate;
    if (g_start >= threshold) {
        g_audio.erase(g_audio.begin(), g_audio.begin() + (ptrdiff_t) g_start);
        g_base_sample += (int64_t) g_start;
        g_start = 0;
    }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_offline_1stt_1demo_WhisperNative_init(JNIEnv *env, jclass, jstring modelPathJ) {
    const char *modelPath = env->GetStringUTFChars(modelPathJ, nullptr);
    LOGI("init() modelPath=%s", modelPath ? modelPath : "(null)");

    {
        ScopeTimer timer("native.init_total");
        std::lock_guard<std::mutex> lk(g_ctx_mu);

        if (g_ctx) {
            whisper_free(g_ctx);
            g_ctx = nullptr;
        }

        g_ctx = whisper_init_from_file(modelPath);
    }

    env->ReleaseStringUTFChars(modelPathJ, modelPath);

    if (!g_ctx) {
        LOGE("whisper_init_from_file failed");
        return JNI_FALSE;
    }

    {
        std::lock_guard<std::mutex> lk(g_audio_mu);
        g_audio.clear();
        g_start = 0;
        g_base_sample = 0;
    }

    LOGI("Whisper init OK");
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_offline_1stt_1demo_WhisperNative_reset(JNIEnv *, jclass) {
    std::lock_guard<std::mutex> lk(g_audio_mu);
    g_audio.clear();
    g_start = 0;
    g_base_sample = 0;
    LOGI("Whisper reset OK");
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_offline_1stt_1demo_WhisperNative_pushPcm16(JNIEnv *env, jclass, jshortArray pcmJ) {
    ScopeTimer timer("native.pushPcm16_total");

    const jsize n = env->GetArrayLength(pcmJ);
    jshort *pcm = env->GetShortArrayElements(pcmJ, nullptr);

    int peak = 0;

    {
        std::lock_guard<std::mutex> lk(g_audio_mu);

        g_audio.reserve(g_audio.size() + (size_t) n);
        for (int i = 0; i < n; i++) {
            int v = std::abs((int) pcm[i]);
            if (v > peak) peak = v;
            g_audio.push_back((float) pcm[i] / 32768.0f);
        }

        const size_t live = live_size_locked();
        if (live > (size_t) kKeepSamples) {
            const size_t new_live_start = g_audio.size() - (size_t) kKeepSamples;
            g_start = std::max(g_start, new_live_start);
        }

        compact_if_needed_locked();
    }

    env->ReleaseShortArrayElements(pcmJ, pcm, JNI_ABORT);

    if (peak < 200) {
        LOGW("pushPcm16: very low audio peak detected (%d)", peak);
    }
}

static bool build_chunk_from_live_audio(float seconds, std::vector<float> &chunk, size_t &liveOut) {
    ScopeTimer timer("native.audio_snapshot");

    std::lock_guard<std::mutex> lk(g_audio_mu);

    const size_t live = live_size_locked();
    liveOut = live;

    if (live == 0) {
        LOGD("build_chunk_from_live_audio: no live audio");
        return false;
    }

    const int want_i = std::max(1, (int) (seconds * (float) kSampleRate));
    const size_t want = (size_t) want_i;
    const size_t count = std::min(live, want);

    const size_t end = g_audio.size();
    const size_t start = end - count;

    chunk.assign(g_audio.begin() + (ptrdiff_t) start, g_audio.end());

    LOGI("audio snapshot: live=%zu want=%zu chunk=%zu", live, want, chunk.size());
    return true;
}

static std::string decode_chunk_with_whisper(const std::vector<float> &chunk, long long &decodeMs, int &nsegOut) {
    std::lock_guard<std::mutex> lk(g_ctx_mu);

    if (!g_ctx) {
        LOGW("decode_chunk_with_whisper: g_ctx is null");
        decodeMs = -1;
        nsegOut = -1;
        return "";
    }

    whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.print_progress = false;
    p.print_realtime = false;
    p.print_timestamps = false;
    p.translate = false;
    p.language = "en";
    p.n_threads = 2;
    p.no_context = true;

    // Let Whisper produce normal output for the whole utterance.
    // Do not artificially cap it to the first short fragment.
    p.single_segment = false;
    p.max_tokens = 0;

    LOGI("Calling whisper_full on chunkSamples=%d chunkSeconds=%.2f",
         (int) chunk.size(),
         (double) chunk.size() / (double) kSampleRate);

    const auto t0 = std::chrono::steady_clock::now();
    const int rc = whisper_full(g_ctx, p, chunk.data(), (int) chunk.size());
    const auto t1 = std::chrono::steady_clock::now();

    decodeMs = std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
    LOGI("whisper_full returned rc=%d in %lld ms", rc, decodeMs);

    if (rc != 0) {
        nsegOut = -1;
        return "";
    }

    {
        ScopeTimer timer("native.segment_join");

        const int nseg = whisper_full_n_segments(g_ctx);
        nsegOut = nseg;
        LOGI("whisper_full produced nseg=%d", nseg);

        std::string joined;
        for (int i = 0; i < nseg; i++) {
            std::string text = whisper_full_get_segment_text(g_ctx, i);
            text = strip_special_tokens(text);
            trim(text);
            if (text.empty()) continue;

            if (!joined.empty()) joined.push_back(' ');
            joined += text;
        }

        trim(joined);
        LOGI("decode_chunk_with_whisper returning len=%zu text='%s'", joined.size(), joined.c_str());
        return joined;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_offline_1stt_1demo_WhisperNative_decodePartial(JNIEnv *env, jclass, jfloat seconds) {
    ScopeTimer total("native.decodePartial_total");
    LOGI("decodePartial called, seconds=%.2f", seconds);

    std::vector<float> chunk;
    size_t live = 0;

    if (!build_chunk_from_live_audio(seconds, chunk, live)) {
        return env->NewStringUTF("");
    }

    long long decodeMs = -1;
    int nseg = -1;
    std::string joined = decode_chunk_with_whisper(chunk, decodeMs, nseg);

    if (!joined.empty()) {
        LOGI("decodePartial returning text len=%zu", joined.size());
        return env->NewStringUTF(joined.c_str());
    }

    if (kReturnDebugStatusWhenEmpty) {
        char msg[160];
        std::snprintf(
            msg,
            sizeof(msg),
            "decode-empty live=%zu chunk=%zu nseg=%d decodeMs=%lld",
            live,
            chunk.size(),
            nseg,
            decodeMs
        );
        LOGI("%s", msg);
        return env->NewStringUTF(msg);
    }

    return env->NewStringUTF("");
}