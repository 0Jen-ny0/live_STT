package com.example.offline_stt_demo

import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {

    private val methodsChannelName = "offline_stt/methods"
    private val eventsChannelName = "offline_stt/events"

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var streamController: WhisperStreamController? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventsChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initModel" -> handleInitModel(call, result)
                    "startStreaming" -> handleStartStreaming(call, result)
                    "stopStreaming" -> handleStopStreaming(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleInitModel(call: MethodCall, result: MethodChannel.Result) {
        try {
            val assetPath = call.argument<String>("assetPath")
                ?: return result.error("bad_args", "Missing assetPath", null)

            val threads = call.argument<Int>("threads") ?: 4
            val modelFile = copyFlutterAssetToFilesDir(assetPath)

            if (streamController == null) {
                streamController = WhisperStreamController { event ->
                    mainHandler.post {
                        eventSink?.success(event)
                    }
                }
            }

            val ok = streamController!!.initModel(modelFile.absolutePath, threads)
            if (!ok) {
                return result.error("init_failed", "Failed to initialize whisper model", null)
            }

            result.success(true)
        } catch (e: Exception) {
            result.error("init_exception", e.message, null)
        }
    }

    private fun handleStartStreaming(call: MethodCall, result: MethodChannel.Result) {
        try {
            val stepMs = call.argument<Int>("stepMs") ?: 400
            val windowMs = call.argument<Int>("windowMs") ?: 5000
            val keepMs = call.argument<Int>("keepMs") ?: 200
            val language = call.argument<String>("language") ?: "en"
            val audioCtx = call.argument<Int>("audioCtx") ?: 512

            val controller = streamController
                ?: return result.error("not_initialized", "Call initModel first", null)

            controller.start(
                stepMs = stepMs,
                windowMs = windowMs,
                keepMs = keepMs,
                language = language,
                audioCtx = audioCtx,
            )

            result.success(true)
        } catch (e: Exception) {
            result.error("start_exception", e.message, null)
        }
    }

    private fun handleStopStreaming(result: MethodChannel.Result) {
        try {
            streamController?.stop()
            result.success(true)
        } catch (e: Exception) {
            result.error("stop_exception", e.message, null)
        }
    }

    private fun copyFlutterAssetToFilesDir(assetPath: String): File {
        val lookupKey = FlutterInjector.instance()
            .flutterLoader()
            .getLookupKeyForAsset(assetPath)

        val fileName = assetPath.substringAfterLast('/')
        val outFile = File(filesDir, fileName)

        assets.open(lookupKey).use { input ->
            FileOutputStream(outFile).use { output ->
                input.copyTo(output)
            }
        }

        return outFile
    }

    override fun onDestroy() {
        streamController?.release()
        super.onDestroy()
    }
}