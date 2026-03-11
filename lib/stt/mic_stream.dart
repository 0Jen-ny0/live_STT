import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/public/flutter_sound.dart';

class MicPcmStream {
  // ==============================
  // Native microphone recorder
  // ==============================
  final FlutterSoundRecorder _rec = FlutterSoundRecorder();

  // ==============================
  // Internal raw input stream:
  // flutter_sound writes PCM16 bytes here
  // ==============================
  final StreamController<Uint8List> _inCtrl =
      StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _inSub;

  // ==============================
  // Output stream:
  // your app reads stable 20 ms PCM16 @ 16 kHz frames from here
  // ==============================
  final StreamController<Uint8List> _outCtrl =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get stream => _outCtrl.stream;

  // ==============================
  // Rolling byte buffer used to reframe raw incoming PCM
  // into fixed-size 20 ms packets
  // ==============================
  final BytesBuilder _buf = BytesBuilder(copy: false);

  // ==============================
  // Recorder state
  // ==============================
  bool _opened = false;
  bool _running = false;

  // Actual microphone sample rate currently in use.
  // Ideally 16000, but some devices only allow 48000 / 44100.
  int _actualSampleRate = 16000;
  int get actualSampleRate => _actualSampleRate;

  // 20 ms @ 16 kHz mono PCM16:
  // 16000 samples/sec * 0.02 sec = 320 samples
  // 320 samples * 2 bytes/sample = 640 bytes
  static const int _frameBytes = 640;

  // ==============================
  // Debug counters for console logging
  // ==============================
  int _rawChunkCount = 0;
  int _outFrameCount = 0;
  int _resampleCount = 0;
  int _bytesReceived = 0;

  void _log(String msg) {
    debugPrint('[MicPcmStream] $msg');
  }

  // Quick signal sanity check:
  // estimate peak amplitude from PCM16 bytes.
    int _estimatePeak(Uint8List bytes) {
    final sampleCount = bytes.lengthInBytes ~/ 2;
    if (sampleCount <= 0) return 0;

    final bd = ByteData.sublistView(bytes);
    int peak = 0;

    for (int i = 0; i < sampleCount; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      final a = s.abs();
      if (a > peak) peak = a;
    }

    return peak;
  }

  Future<void> start({int sampleRate = 16000, int numChannels = 1}) async {
    _log(
      'start() requested sampleRate=$sampleRate numChannels=$numChannels '
      'running=$_running opened=$_opened',
    );

    if (_running) {
      _log('start() ignored because recorder is already running');
      return;
    }

    if (!_opened) {
      final sw = Stopwatch()..start();
      await _rec.openRecorder();
      sw.stop();
      _opened = true;
      _log('Recorder opened in ${sw.elapsedMilliseconds} ms');
    }

    // Reset counters/state for a fresh run
    _rawChunkCount = 0;
    _outFrameCount = 0;
    _resampleCount = 0;
    _bytesReceived = 0;
    _buf.clear();

    // ==============================
    // Listen to raw PCM16 bytes from flutter_sound
    // Pipeline:
    // raw mic bytes -> optional resample -> fixed 20 ms frames -> _outCtrl
    // ==============================
    await _inSub?.cancel();
    
    _inSub = _inCtrl.stream.listen(
  (Uint8List raw) {
    try {
      if (raw.isEmpty) {
        _log('Received empty raw audio chunk');
        return;
      }

      final chunkSw = Stopwatch()..start();

      _rawChunkCount++;
      _bytesReceived += raw.length;

      final rawPeak = _estimatePeak(raw);
      if (_rawChunkCount % 20 == 1) {
        _log(
          'Raw chunk #$_rawChunkCount bytes=${raw.length} '
          'offset=${raw.offsetInBytes} peak=$rawPeak actualSampleRate=$_actualSampleRate',
        );
      }

      Uint8List pcm16 = raw;

      if (_actualSampleRate != 16000) {
        final resampleSw = Stopwatch()..start();
        pcm16 = _resamplePcm16To16k(pcm16, _actualSampleRate);
        resampleSw.stop();

        _resampleCount++;
        _log(
          'Resampled chunk #$_resampleCount from $_actualSampleRate Hz '
          'to 16000 Hz in ${resampleSw.elapsedMilliseconds} ms '
          '(inBytes=${raw.length}, outBytes=${pcm16.length})',
        );
      }

      _buf.add(pcm16);
      final all = _buf.toBytes();

      int off = 0;
      int framesProducedThisChunk = 0;

      while (off + _frameBytes <= all.length) {
        _outCtrl.add(Uint8List.sublistView(all, off, off + _frameBytes));
        off += _frameBytes;
        framesProducedThisChunk++;
        _outFrameCount++;
      }

      _buf.clear();
      if (off < all.length) {
        _buf.add(Uint8List.sublistView(all, off));
      }

      chunkSw.stop();

      if (_rawChunkCount % 20 == 1 || framesProducedThisChunk > 1) {
        _log(
          'Processed raw chunk #$_rawChunkCount -> '
          '$framesProducedThisChunk output frame(s), '
          'leftoverBytes=${all.length - off}, '
          'totalOutFrames=$_outFrameCount, '
          'chunkTime=${chunkSw.elapsedMilliseconds} ms',
        );
      }
    } catch (e, st) {
      _log('Mic stream processing error: $e');
      debugPrint('$st');
    }
  },
  onError: (Object e, StackTrace st) {
    _log('Input stream error: $e');
    debugPrint('$st');
  },
  onDone: () {
    _log('Input stream closed');
  },
  cancelOnError: false,
);

    // ==============================
    // Try 16 kHz first; if device does not support it,
    // fall back to 48 kHz / 44.1 kHz and resample in Dart
    // ==============================
    final tryRates = <int>[sampleRate, 48000, 44100].toSet().toList();
    Exception? lastErr;

    _log('Trying recorder sample rates: $tryRates');

    for (final sr in tryRates) {
      try {
        final sw = Stopwatch()..start();

        _actualSampleRate = sr;

        await _rec.startRecorder(
          codec: Codec.pcm16,
          numChannels: numChannels,
          sampleRate: sr,
          audioSource: AudioSource.microphone,
          toStream: _inCtrl.sink,
        );

        sw.stop();
        _running = true;

        _log(
          'Recorder started successfully in ${sw.elapsedMilliseconds} ms '
          'sampleRate=$_actualSampleRate channels=$numChannels',
        );
        return;
      } catch (e) {
        lastErr = e is Exception ? e : Exception(e.toString());
        _log('Failed to start recorder at $sr Hz: $e');

        try {
          await _rec.stopRecorder();
        } catch (_) {}
      }
    }

    _log('All recorder start attempts failed');
    throw lastErr ?? Exception('Failed to start recorder');
  }

  Future<void> stop() async {
    _log('stop() requested running=$_running');

    if (!_running) {
      _log('stop() ignored because recorder is not running');
      return;
    }

    _running = false;

    try {
      final sw = Stopwatch()..start();
      await _rec.stopRecorder();
      sw.stop();

      _log(
        'Recorder stopped in ${sw.elapsedMilliseconds} ms '
        'rawChunks=$_rawChunkCount outFrames=$_outFrameCount '
        'bytesReceived=$_bytesReceived resamples=$_resampleCount '
        'leftoverBufferedBytes=${_buf.length}',
      );
    } catch (e) {
      _log('stopRecorder() failed: $e');
    }
  }

  Future<void> dispose() async {
    _log('dispose() called');

    await stop();

    await _inSub?.cancel();
    _inSub = null;
    _log('Input subscription cancelled');

    if (_opened) {
      try {
        final sw = Stopwatch()..start();
        await _rec.closeRecorder();
        sw.stop();
        _log('Recorder closed in ${sw.elapsedMilliseconds} ms');
      } catch (e) {
        _log('closeRecorder() failed: $e');
      }
      _opened = false;
    }

    await _inCtrl.close();
    await _outCtrl.close();
    _log('Stream controllers closed');
  }

  // ==============================
  // Resampling: PCM16 LE bytes -> PCM16 LE bytes at 16 kHz
  // ==============================
    Uint8List _resamplePcm16To16k(Uint8List inBytes, int inRate) {
    if (inRate == 16000) return inBytes;

    final sampleCount = inBytes.lengthInBytes ~/ 2;
    if (sampleCount <= 0) return Uint8List(0);

    final bd = ByteData.sublistView(inBytes);

    // Read safely from possibly unaligned PCM bytes
    final inSamp = Int16List(sampleCount);
    for (int i = 0; i < sampleCount; i++) {
      inSamp[i] = bd.getInt16(i * 2, Endian.little);
    }

    // Fast path 48k -> 16k
    if (inRate == 48000) {
      final outLen = inSamp.length ~/ 3;
      final out = Int16List(outLen);
      int j = 0;
      for (int i = 0; i + 2 < inSamp.length; i += 3) {
        out[j++] = inSamp[i];
      }
      return Uint8List.view(out.buffer);
    }

    // Generic linear resampler
    final ratio = inRate / 16000.0;
    final outLen = max(1, (inSamp.length / ratio).floor());
    final out = Int16List(outLen);

    double srcPos = 0.0;
    for (int i = 0; i < outLen; i++) {
      final i0 = srcPos.floor();
      final i1 = min(i0 + 1, inSamp.length - 1);
      final t = srcPos - i0;

      final s0 = inSamp[i0];
      final s1 = inSamp[i1];
      final v = (s0 + (s1 - s0) * t).round();

      out[i] = v.clamp(-32768, 32767);
      srcPos += ratio;
      if (srcPos >= inSamp.length - 1) break;
    }

    return Uint8List.view(out.buffer);
  }
}