package com.example.offline_stt_demo

import android.content.res.AssetManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.min

class MainActivity : FlutterActivity() {

    private val METHODS = "offline_stt/methods"
    private val EVENTS = "offline_stt/events"

    private val TAG = "WhisperMain"
    private val PERF = "WhisperPerf"

    private val FORCE_RECOPY_MODEL = true

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private val workerThread = HandlerThread("whisper_worker").apply { start() }
    private val worker = Handler(workerThread.looper)

    @Volatile private var running = false
    @Volatile private var decoding = false
    @Volatile private var decodeStartedAtMs: Long = 0L

    private val tickMs: Long = 200
    private val decodeSeconds: Float = 1.0f
    private val minDecodeSamples: Long = 16000L

    @Volatile private var samplesPushed: Long = 0
    @Volatile private var samplesLastDecoded: Long = 0

    private var lastSentText: String = ""

    private fun logD(message: String) = Log.d(TAG, message)
    private fun logI(message: String) = Log.i(TAG, message)
    private fun logW(message: String) = Log.w(TAG, message)
    private fun logE(message: String, e: Exception? = null) = Log.e(TAG, message, e)

    private class PerfTimer(private val tag: String, private val name: String) {
        private val start = SystemClock.elapsedRealtime()
        fun done(extra: String = "") {
            val dt = SystemClock.elapsedRealtime() - start
            val suffix = if (extra.isEmpty()) "" else " $extra"
            Log.d(tag, "$name took ${dt} ms$suffix")
        }
    }

    private fun cleanText(raw: String): String {
        return raw
            .replace("[BLANK_AUDIO]", "")
            .replace("[MUSIC]", "")
            .replace("[NOISE]", "")
            .trim()
    }

    private fun gateState(): String {
        val newSamples = samplesPushed - samplesLastDecoded
        return "running=$running decoding=$decoding " +
            "samplesPushed=$samplesPushed samplesLastDecoded=$samplesLastDecoded newSamples=$newSamples"
    }

    private val decodeWatchdog = object : Runnable {
        override fun run() {
            if (decoding) {
                val stuckMs = SystemClock.elapsedRealtime() - decodeStartedAtMs
                logW("Decode still running after ${stuckMs} ms")
                mainHandler.postDelayed(this, 1000)
            }
        }
    }

    private fun scheduleDecode(reason: String) {
        logD("scheduleDecode(reason=$reason) thread=${Thread.currentThread().name} ${gateState()}")
        worker.removeCallbacks(decodeRunnable)
        worker.post(decodeRunnable)
    }

    private val decodeRunnable = object : Runnable {
        override fun run() {
            logD("decodeRunnable ENTER thread=${Thread.currentThread().name} ${gateState()}")

            if (!running) {
                logD("decodeRunnable EXIT because running=false")
                return
            }

            val newSamples = samplesPushed - samplesLastDecoded
            if (newSamples < minDecodeSamples) {
                logD("decodeRunnable SKIP not enough new audio: $newSamples / $minDecodeSamples")
                worker.postDelayed(this, tickMs)
                return
            }

            if (decoding) {
                logD("decodeRunnable SKIP because decoding=true")
                worker.postDelayed(this, tickMs)
                return
            }

            decoding = true
            decodeStartedAtMs = SystemClock.elapsedRealtime()
            samplesLastDecoded = samplesPushed
            mainHandler.removeCallbacks(decodeWatchdog)
            mainHandler.postDelayed(decodeWatchdog, 1000)

            try {
                val timer = PerfTimer(PERF, "kotlin.decodePartial_total")
                logD("Calling WhisperNative.decodePartial(seconds=$decodeSeconds)")
                val raw = WhisperNative.decodePartial(decodeSeconds)
                timer.done("rawLen=${raw.length}")
                logD("decodePartial raw head='${raw.take(80)}'")

                val text = cleanText(raw)
                logD("decoded clean len=${text.length}")

                if (text.isNotEmpty() && text != lastSentText) {
                    lastSentText = text
                    logI("Sending partial to Flutter len=${text.length}")
                    mainHandler.post {
                        eventSink?.success(
                            mapOf(
                                "type" to "partial",
                                "text" to text
                            )
                        )
                    }
                }
            } catch (e: Exception) {
                logE("decodePartial error", e)
            } finally {
                decoding = false
                decodeStartedAtMs = 0L
                mainHandler.removeCallbacks(decodeWatchdog)

                if (running) {
                    worker.postDelayed(this, tickMs)
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        logI("configureFlutterEngine() thread=${Thread.currentThread().name}")

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    logI("EventChannel listener attached")
                    eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    logI("EventChannel listener removed")
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHODS)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                logD("Method call received: ${call.method}")

                when (call.method) {

                    "init" -> {
                        val rel = call.argument<String>("asset")
                            ?: "assets/models/ggml-tiny.en.bin"
                        val assetKey = "flutter_assets/$rel"
                        val outName = rel.substringAfterLast('/')

                        logI("Init requested with asset='$rel'")

                        val modelFile = try {
                            copyAssetToFiles(assetKey, outName)
                        } catch (e: Exception) {
                            logE("copyAsset failed", e)
                            result.error("ERR", "copyAsset failed: ${e.message}", e.toString())
                            return@setMethodCallHandler
                        }

                        worker.post {
                            try {
                                val timer = PerfTimer(PERF, "kotlin.native_init")
                                val ok = WhisperNative.init(modelFile.absolutePath)
                                timer.done("ok=$ok model=${modelFile.name}")
                                logI("Native init complete ok=$ok")
                                mainHandler.post { result.success(ok) }
                            } catch (e: Exception) {
                                logE("Native init failed", e)
                                mainHandler.post { result.error("ERR", e.message, e.toString()) }
                            }
                        }
                    }

                    "start" -> {
                        logI("Start requested from Flutter")

                        running = true
                        decoding = false
                        decodeStartedAtMs = 0L
                        samplesPushed = 0
                        samplesLastDecoded = 0
                        lastSentText = ""

                        try {
                            WhisperNative.reset()
                            logI("WhisperNative.reset() ok")
                        } catch (e: Exception) {
                            logW("WhisperNative.reset() failed: ${e.message}")
                        }

                        logI("After start state: ${gateState()}")
                        scheduleDecode("start")
                        result.success(true)
                    }

                    "stop" -> {
                        logI("Stop requested from Flutter")
                        logI("Before stop state: ${gateState()}")

                        running = false
                        decoding = false
                        decodeStartedAtMs = 0L
                        samplesLastDecoded = samplesPushed
                        worker.removeCallbacks(decodeRunnable)
                        mainHandler.removeCallbacks(decodeWatchdog)

                        val finalOut = lastSentText.trim()
                        logI("Final transcript len=${finalOut.length}")

                        if (finalOut.isNotEmpty()) {
                            mainHandler.post {
                                eventSink?.success(
                                    mapOf(
                                        "type" to "final",
                                        "text" to finalOut
                                    )
                                )
                            }
                            logI("Final transcript sent to Flutter")
                        }

                        result.success(true)
                    }

                    "pushPcmBytes" -> {
                        val totalTimer = PerfTimer(PERF, "kotlin.pushPcmBytes_total")

                        if (!running) {
                            logW("Dropping PCM because native STT is not running. ${gateState()}")
                            result.success(false)
                            return@setMethodCallHandler
                        }

                        val bytes = call.argument<ByteArray>("pcm")
                        if (bytes == null) {
                            logW("pushPcmBytes missing 'pcm'")
                            result.error("ARG", "missing 'pcm' ByteArray", null)
                            return@setMethodCallHandler
                        }

                        if (bytes.size % 2 != 0) {
                            logW("PCM byte array odd length=${bytes.size}")
                        }

                        val nShorts = bytes.size / 2
                        val shorts = ShortArray(nShorts)

                        val convertTimer = PerfTimer(PERF, "kotlin.pcm_convert")
                        ByteBuffer.wrap(bytes)
                            .order(ByteOrder.LITTLE_ENDIAN)
                            .asShortBuffer()
                            .get(shorts)
                        convertTimer.done("nShorts=$nShorts")

                        samplesPushed += nShorts.toLong()

                        var peak = 0
                        val checkN = min(200, shorts.size)
                        for (i in 0 until checkN) {
                            peak = maxOf(peak, abs(shorts[i].toInt()))
                        }

                        logD("pushPcmBytes: nShorts=$nShorts peak=$peak totalSamples=$samplesPushed")

                        try {
                            val nativePushTimer = PerfTimer(PERF, "kotlin.jni_push")
                            WhisperNative.pushPcm16(shorts)
                            nativePushTimer.done()
                        } catch (e: Exception) {
                            logE("WhisperNative.pushPcm16 failed", e)
                        }

                        val newSamples = samplesPushed - samplesLastDecoded
                        logD("Gate after push: ${gateState()}")

                        if (running && !decoding && newSamples >= minDecodeSamples) {
                            scheduleDecode("pushPcmBytes")
                        }

                        totalTimer.done()
                        result.success(true)
                    }

                    else -> {
                        logW("Method not implemented: ${call.method}")
                        result.notImplemented()
                    }
                }
            }
    }

    override fun onDestroy() {
        logI("onDestroy() called")
        running = false
        decoding = false
        worker.removeCallbacks(decodeRunnable)
        mainHandler.removeCallbacks(decodeWatchdog)
        workerThread.quitSafely()
        super.onDestroy()
    }

    private fun copyAssetToFiles(assetKey: String, outName: String): File {
        val outFile = File(filesDir, outName)

        if (FORCE_RECOPY_MODEL && outFile.exists()) {
            logW("Deleting existing cached model: ${outFile.absolutePath} (${outFile.length()} bytes)")
            outFile.delete()
        }

        if (outFile.exists() && outFile.length() > 0L) {
            logI("Model already exists: ${outFile.absolutePath} (${outFile.length()} bytes)")
            return outFile
        }

        logI("Copying asset '$assetKey' to '${outFile.absolutePath}'")

        val am: AssetManager = assets
        am.open(assetKey).use { input ->
            FileOutputStream(outFile, false).use { output ->
                input.copyTo(output)
                output.flush()
            }
        }

        logI("Model copied successfully: ${outFile.absolutePath} (${outFile.length()} bytes)")
        return outFile
    }
}