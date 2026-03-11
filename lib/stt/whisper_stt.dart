import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'perf_timer.dart';
import 'stt.dart';

class WhisperStt implements OfflineStt {
  static const MethodChannel _m = MethodChannel('offline_stt/methods');
  static const EventChannel _e = EventChannel('offline_stt/events');

  final _partialCtrl = StreamController<String>.broadcast();
  final _finalCtrl = StreamController<String>.broadcast();

  StreamSubscription<dynamic>? _sub;
  bool _inited = false;

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

  @override
  Future<void> init() async {
    _log('init() called, inited=$_inited');
    if (_inited) return;

    const asset = 'assets/models/ggml-tiny.en.bin';
    final t = PerfTimer('stt.init');

    final ok = await _m.invokeMethod<bool>('init', {'asset': asset});
    t.done('ok=$ok asset=$asset');

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
            if (_partialEventCount % 5 == 1) {
              _log('partial #$_partialEventCount len=${text.length}');
            }
            _partialCtrl.add(text);
          } else if (type == 'final') {
            _finalEventCount++;
            _log('final #$_finalEventCount len=${text.length}');
            _finalCtrl.add(text);
          } else {
            _log('unknown event: $map');
          }
        } else {
          _log('non-map event: $event');
        }
      },
      onError: (Object e, StackTrace st) {
        _log('EventChannel error: $e');
      },
      onDone: () {
        _log('EventChannel closed');
      },
      cancelOnError: false,
    );

    _inited = true;
    _log('init complete');
  }

  @override
  Future<void> start() async {
    if (!_inited) {
      await init();
    }

    final t = PerfTimer('stt.start');
    await _m.invokeMethod('start');
    t.done();
  }

  @override
  Future<void> stop() async {
    final t = PerfTimer('stt.stop');
    await _m.invokeMethod('stop');
    t.done();
  }

  Future<bool> pushPcmBytes(Uint8List pcm16leBytes) async {
    if (!_inited) {
      _log('pushPcmBytes ignored because not initialized');
      return false;
    }

    _pushCount++;
    _pushBytesTotal += pcm16leBytes.lengthInBytes;

    final t = PerfTimer('method.pushPcmBytes');
    final ok = await _m.invokeMethod<bool>('pushPcmBytes', {'pcm': pcm16leBytes});
    t.done('ok=$ok bytes=${pcm16leBytes.lengthInBytes}');

    if (_pushCount % 25 == 1) {
      _log(
        'push #$_pushCount bytes=${pcm16leBytes.lengthInBytes} '
        'totalBytes=$_pushBytesTotal ok=$ok',
      );
    }

    return ok == true;
  }

  Future<String> flushDecode() async {
    if (!_inited) return '';

    final t = PerfTimer('stt.flushDecode');
    final text = await _m.invokeMethod<String>('flushDecode') ?? '';
    t.done('len=${text.length}');
    return text;
  }

  Future<void> dispose() async {
    _log(
      'dispose() partials=$_partialEventCount finals=$_finalEventCount '
      'pushCount=$_pushCount pushBytes=$_pushBytesTotal',
    );

    await _sub?.cancel();
    _sub = null;

    await _partialCtrl.close();
    await _finalCtrl.close();
  }
}