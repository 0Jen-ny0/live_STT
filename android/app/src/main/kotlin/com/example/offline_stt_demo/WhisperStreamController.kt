package com.example.offline_stt_demo

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

class WhisperStreamController(
    private val onEvent: (Map<String, Any>) -> Unit
) {
    private val sampleRate = 16_000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT
    private val audioSource = MediaRecorder.AudioSource.VOICE_RECOGNITION

    private val ringBuffer = FloatRingBuffer(sampleRate * 10) // 10 seconds

    @Volatile
    private var initialized = false

    @Volatile
    private var streaming = false

    @Volatile
    private var decoding = false

    private var audioRecord: AudioRecord? = null
    private var recordThread: Thread? = null
    private var decodeExecutor: ScheduledExecutorService? = null

    private var stableText: String = ""
    private var lastHypothesis: String = ""

    fun initModel(modelPath: String, threads: Int): Boolean {
        stop()

        if (initialized) {
            WhisperNative.freeContext()
            initialized = false
        }

        val ok = WhisperNative.initContext(modelPath, threads)
        initialized = ok
        return ok
    }

    fun start(
        stepMs: Int,
        windowMs: Int,
        keepMs: Int,
        language: String,
        audioCtx: Int,
    ) {
        require(initialized) { "Model not initialized" }

        if (streaming) return

        ringBuffer.clear()
        stableText = ""
        lastHypothesis = ""

        streaming = true

        startRecorder()
        scheduleDecodeLoop(
            stepMs = stepMs,
            windowMs = windowMs,
            keepMs = keepMs,
            language = language,
            audioCtx = audioCtx,
        )

        onEvent(mapOf("type" to "status", "status" to "listening"))
    }

    fun stop() {
        streaming = false
        stopRecorder()

        decodeExecutor?.shutdownNow()
        decodeExecutor = null
        decoding = false

        onEvent(mapOf("type" to "status", "status" to "idle"))
    }

    fun release() {
        stop()
        if (initialized) {
            WhisperNative.freeContext()
            initialized = false
        }
    }

    private fun startRecorder() {
        val minBufferBytes = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        require(minBufferBytes > 0) { "Invalid AudioRecord buffer size: $minBufferBytes" }

        val recorder = AudioRecord(
            audioSource,
            sampleRate,
            channelConfig,
            audioFormat,
            minBufferBytes * 4
        )

        require(recorder.state == AudioRecord.STATE_INITIALIZED) {
            "AudioRecord initialization failed"
        }

        recorder.startRecording()

        if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            recorder.release()
            error("AudioRecord start failed")
        }

        audioRecord = recorder

        recordThread = Thread {
            val shortBuffer = ShortArray(minBufferBytes / 2)

            try {
                while (streaming && !Thread.currentThread().isInterrupted) {
                    val read = recorder.read(shortBuffer, 0, shortBuffer.size)
                    if (read > 0) {
                        val floatChunk = FloatArray(read)
                        for (i in 0 until read) {
                            floatChunk[i] = shortBuffer[i] / 32768.0f
                        }
                        ringBuffer.append(floatChunk)
                    }
                }
            } catch (e: Exception) {
                onEvent(
                    mapOf(
                        "type" to "error",
                        "message" to (e.message ?: "Audio recorder thread failed")
                    )
                )
            }
        }.apply {
            name = "WhisperMicThread"
            start()
        }
    }

    private fun stopRecorder() {
        try {
            recordThread?.interrupt()
            recordThread?.join(300)
        } catch (_: Exception) {
        } finally {
            recordThread = null
        }

        try {
            audioRecord?.let { recorder ->
                if (recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                    recorder.stop()
                }
                recorder.release()
            }
        } catch (_: Exception) {
        } finally {
            audioRecord = null
        }
    }

    private fun scheduleDecodeLoop(
        stepMs: Int,
        windowMs: Int,
        keepMs: Int,
        language: String,
        audioCtx: Int,
    ) {
        decodeExecutor = Executors.newSingleThreadScheduledExecutor()

        decodeExecutor?.scheduleAtFixedRate({
            if (!streaming) return@scheduleAtFixedRate
            if (decoding) return@scheduleAtFixedRate

            val windowSamples = (sampleRate * windowMs) / 1000
            val minSamplesToDecode = sampleRate // wait until at least 1 second of audio
            val audioWindow = ringBuffer.lastSamples(windowSamples)

            if (audioWindow.size < minSamplesToDecode) return@scheduleAtFixedRate

            decoding = true

            try {
                onEvent(mapOf("type" to "status", "status" to "decoding"))

                // keepMs is accepted to mirror whisper-stream style config.
                // This scaffold decodes the last fixed window directly.
                @Suppress("UNUSED_VARIABLE")
                val keepOverlapMs = keepMs

                val text = WhisperNative
                    .transcribeWindow(audioWindow, language, audioCtx)
                    .trim()

                val common = longestCommonPrefixOnWordBoundary(lastHypothesis, text)

                if (common.length > stableText.length) {
                    stableText = common
                }

                if (!text.startsWith(stableText)) {
                    stableText = longestCommonPrefixOnWordBoundary(stableText, text)
                }

                val partialText = text.removePrefix(stableText).trimStart()
                val fullText = listOf(stableText.trim(), partialText)
                    .filter { it.isNotEmpty() }
                    .joinToString(" ")
                    .trim()

                onEvent(
                    mapOf(
                        "type" to "transcript",
                        "stableText" to stableText.trim(),
                        "partialText" to partialText,
                        "fullText" to fullText,
                    )
                )

                lastHypothesis = text
                onEvent(mapOf("type" to "status", "status" to "listening"))
            } catch (e: Exception) {
                onEvent(
                    mapOf(
                        "type" to "error",
                        "message" to (e.message ?: "Decode failed")
                    )
                )
            } finally {
                decoding = false
            }
        }, 0, stepMs.toLong(), TimeUnit.MILLISECONDS)
    }

    private fun longestCommonPrefixOnWordBoundary(a: String, b: String): String {
        val max = minOf(a.length, b.length)
        var i = 0

        while (i < max && a[i] == b[i]) {
            i++
        }

        if (i == 0) return ""

        var boundary = i
        while (boundary > 0) {
            val ch = a[boundary - 1]
            if (ch.isWhitespace() || ch == '.' || ch == ',' || ch == '!' || ch == '?' || ch == ';' || ch == ':') {
                break
            }
            boundary--
        }

        return a.substring(0, boundary).trimEnd()
    }
}