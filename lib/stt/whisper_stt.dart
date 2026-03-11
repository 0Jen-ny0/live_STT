import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'perf_timer.dart';
import 'stt.dart';


class WhisperStt implements OfflineStt {
  // ==============================
  // Flutter <-> Android channels
  // ==============================
  static const MethodChannel _m = MethodChannel('offline_stt/methods');
  static const EventChannel _e = EventChannel('offline_stt/events');

  // ==============================
  // Output streams for the app UI
  // partial   -> live text updates
  // finalText -> final transcript after stop
  // ==============================
  final _partialCtrl = StreamController<String>.broadcast();
  final _finalCtrl = StreamController<String>.broadcast();

  // Subscription to native EventChannel
  StreamSubscription<dynamic>? _sub;

  // Whether native Whisper has been initialized
  bool _inited = false;

  // Debug counters
  int _partialEventCount = 0;
  int _finalEventCount = 0;
  int _pushCount = 0;
  int _pushBytesTotal = 0;

  void _log(String msg) {
    debugPrint('[WhisperStt] $msg');
  }

  @override
  Stream<String> get partial => _partialCtrl.stream;

  @override
  Stream<String> get finalText => _finalCtrl.stream;

  /// Initialize native Whisper with the model asset path.
  /// This path must exist in pubspec.yaml assets.
  @override
  Future<void> init() async {
    _log('init() called, inited=$_inited');

    if (_inited) {
      _log('init() skipped because Whisper is already initialized');
      return;
    }

    // Change this if you use a different model file name
    const asset = 'assets/models/ggml-tiny.en.bin';

    try {
      final sw = Stopwatch()..start();

      _log('Sending init to native with asset=$asset');
      final ok = await _m.invokeMethod<bool>('init', {'asset': asset});

      sw.stop();
      _log('Native init returned ok=$ok in ${sw.elapsedMilliseconds} ms');

      if (ok != true) {
        throw Exception('Whisper init failed');
      }

      _sub ??= _e.receiveBroadcastStream().listen(
        (event) {
          if (event is Map) {
            final map = Map<String, dynamic>.from(event);
            final type = map['type']?.toString() ?? '';
            final text = map['text']?.toString() ?? '';

            if (type == 'partial') {
              _partialEventCount++;
              _log(
                'Received partial #$_partialEventCount '
                'len=${text.length} text="${text.length > 80 ? text.substring(0, 80) : text}"',
              );
              _partialCtrl.add(text);
            }

            if (type == 'final') {
              _finalEventCount++;
              _log(
                'Received final #$_finalEventCount '
                'len=${text.length} text="${text.length > 80 ? text.substring(0, 80) : text}"',
              );
              _finalCtrl.add(text);
            }

            if (type.isEmpty) {
              _log('Received event with missing type: $map');
            }
          } else {
            _log('Received non-Map event from EventChannel: $event');
          }
        },
        onError: (Object e, StackTrace st) {
          _log('EventChannel error: $e');
        },
        onDone: () {
          _log('EventChannel stream closed');
        },
        cancelOnError: false,
      );

      _inited = true;
      _log('WhisperStt init complete');
    } catch (e) {
      _log('init() failed: $e');
      rethrow;
    }
  }

  /// Start decoding loop on Android (does not start microphone).
  @override
  Future<void> start() async {
    _log('start() called, inited=$_inited');

    if (!_inited) {
      _log('start() calling init() first');
      await init();
    }

    final sw = Stopwatch()..start();
    await _m.invokeMethod('start');
    sw.stop();

    _log('Native start completed in ${sw.elapsedMilliseconds} ms');
  }

  /// Stop decoding loop on Android and emit final text (Android side).
  @override
  Future<void> stop() async {
    _log('stop() called');

    final sw = Stopwatch()..start();
    await _m.invokeMethod('stop');
    sw.stop();

    _log('Native stop completed in ${sw.elapsedMilliseconds} ms');
  }

  /// Push PCM16 little-endian bytes to Android.
  /// Kotlin handles MethodChannel method "pushPcmBytes"
  /// and converts ByteArray -> ShortArray -> JNI pushPcm16().
  Future<bool> pushPcmBytes(Uint8List pcm16leBytes) async {
    if (!_inited) {
      _log('pushPcmBytes() ignored because Whisper is not initialized');
      return false;
    }

    _pushCount++;
    _pushBytesTotal += pcm16leBytes.lengthInBytes;

    final sw = Stopwatch()..start();
    final ok = await _m.invokeMethod<bool>('pushPcmBytes', {'pcm': pcm16leBytes});
    sw.stop();

    if (_pushCount % 25 == 1) {
      _log(
        'pushPcmBytes #$_pushCount '
        'bytes=${pcm16leBytes.lengthInBytes} '
        'totalBytes=$_pushBytesTotal '
        'invokeTime=${sw.elapsedMilliseconds} ms '
        'ok=$ok',
      );
    }

    return ok == true;
  }

  /// Close event subscription and output streams.
  Future<void> dispose() async {
    _log(
      'dispose() called '
      'partialEvents=$_partialEventCount '
      'finalEvents=$_finalEventCount '
      'pushCount=$_pushCount '
      'pushBytes=$_pushBytesTotal',
    );

    await _sub?.cancel();
    _sub = null;
    _log('Event subscription cancelled');

    await _partialCtrl.close();
    await _finalCtrl.close();
    _log('Output stream controllers closed');
  }
}