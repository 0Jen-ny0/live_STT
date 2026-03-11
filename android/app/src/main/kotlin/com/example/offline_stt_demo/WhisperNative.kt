package com.example.offline_stt_demo

object WhisperNative {
    init { System.loadLibrary("whisper_jni") }

    external fun init(modelPath: String): Boolean
    external fun reset()
    external fun pushPcm16(pcm: ShortArray)
    external fun decodePartial(seconds: Float): String
}