package com.example.offline_stt_demo

object WhisperNative {
    init {
        System.loadLibrary("whisper_jni")
    }

    @JvmStatic
    external fun initContext(modelPath: String, threads: Int): Boolean

    @JvmStatic
    external fun freeContext()

    @JvmStatic
    external fun transcribeWindow(
        audio: FloatArray,
        language: String,
        audioCtx: Int,
    ): String
}