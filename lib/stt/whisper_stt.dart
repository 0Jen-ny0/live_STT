import 'package:flutter/services.dart';

class WhisperStt {
  static const MethodChannel _methods = MethodChannel('offline_stt/methods');
  static const EventChannel _events = EventChannel('offline_stt/events');

  Stream<Map<dynamic, dynamic>> get events =>
      _events.receiveBroadcastStream().cast<Map<dynamic, dynamic>>();

  Future<void> initModel({
    required String assetPath,
    int threads = 4,
  }) async {
    await _methods.invokeMethod('initModel', {
      'assetPath': assetPath,
      'threads': threads,
    });
  }

  Future<void> startStreaming({
    int stepMs = 400,
    int windowMs = 5000,
    int keepMs = 200,
    String language = 'en',
    int audioCtx = 512,
  }) async {
    await _methods.invokeMethod('startStreaming', {
      'stepMs': stepMs,
      'windowMs': windowMs,
      'keepMs': keepMs,
      'language': language,
      'audioCtx': audioCtx,
    });
  }

  Future<void> stopStreaming() async {
    await _methods.invokeMethod('stopStreaming');
  }
}