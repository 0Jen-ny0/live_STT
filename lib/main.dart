import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'stt/mic_stream.dart';
import 'stt/perf_timer.dart';
import 'stt/whisper_stt.dart';

void main() => runApp(const OfflineSttDemo());

class OfflineSttDemo extends StatelessWidget {
  const OfflineSttDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline STT Demo',
      theme: ThemeData(useMaterial3: true),
      home: const SttHomePage(),
    );
  }
}

class SttHomePage extends StatefulWidget {
  const SttHomePage({super.key});

  @override
  State<SttHomePage> createState() => _SttHomePageState();
}

class _SttHomePageState extends State<SttHomePage> {
  final WhisperStt stt = WhisperStt();
  final MicPcmStream mic = MicPcmStream();

  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<String>? _pSub;
  StreamSubscription<String>? _fSub;

  String partial = '';
  final List<String> finals = [];

  bool running = false;

  double rms = 0.0;
  double _rmsSmooth = 0.0;

  // ==============================
  // Speech / utterance state
  // ==============================
  bool _utteranceOpen = false;
  bool _sttSessionActive = false;
  bool _sessionStarting = false;
  bool _sessionStopping = false;
  int _lastAboveThresholdMs = 0;

  // ==============================
  // Native send buffers
  // ==============================
  final BytesBuilder _pcmBuf = BytesBuilder(copy: false);
  final BytesBuilder _pendingStartBuf = BytesBuilder(copy: false);
  bool _draining = false;

  // ==============================
  // Pre-roll buffer
  // ==============================
  final ListQueue<Uint8List> _preRollFrames = ListQueue<Uint8List>();
  int _preRollBytes = 0;

  bool _sttReady = false;
  bool _initInProgress = false;

  // 20 ms @ 16 kHz mono PCM16 = 640 bytes
  static const int _frameBytes = 640;

  // Send 200 ms chunks to native
  static const int _sendChunkBytes = 6400;

  // Keep ~300 ms of pre-roll = 15 x 20 ms frames
  static const int _maxPreRollFrames = 15;

  // RMS thresholds
  static const double _speechStartRms = 0.012;
  static const double _speechKeepRms = 0.008;

  // Close utterance after this much silence
  static const int _silenceMsToEnd = 500;

  int _micChunkCount = 0;
  int _chunksSent = 0;
  int _bytesSent = 0;
  int _partialCount = 0;
  int _finalCount = 0;

  void _log(String msg) {
    debugPrint('[MainSTT] $msg');
  }

  @override
  void initState() {
    super.initState();

    _pSub = stt.partial.listen((t) {
      _partialCount++;
      if (_partialCount % 5 == 1) {
        _log('Partial #$_partialCount len=${t.length}');
      }
      if (!mounted) return;
      setState(() => partial = t);
    });

    _fSub = stt.finalText.listen((t) {
      final tt = t.trim();
      if (tt.isEmpty) return;

      _finalCount++;
      _log('Final #$_finalCount len=${tt.length} text="$tt"');

      if (!mounted) return;
      setState(() {
        finals.insert(0, tt);
        partial = '';
      });
    });
  }

  @override
  void dispose() {
    _micSub?.cancel();
    _pSub?.cancel();
    _fSub?.cancel();

    unawaited(stt.dispose());
    unawaited(mic.dispose());

    super.dispose();
  }

  double _fastRms16(Uint8List pcm) {
    final bd = ByteData.sublistView(pcm);
    final n = pcm.length ~/ 2;
    if (n <= 0) return 0.0;

    const step = 6;
    double sumSq = 0.0;
    int count = 0;

    for (int i = 0; i < n; i += step) {
      final s = bd.getInt16(i * 2, Endian.little);
      final v = s / 32768.0;
      sumSq += v * v;
      count++;
    }

    return count > 0 ? sqrt(sumSq / count) : 0.0;
  }

  Future<void> _ensureSttInit() async {
    if (_sttReady || _initInProgress) return;

    _initInProgress = true;
    final t = PerfTimer('main.ensureSttInit');

    try {
      await stt.init();
      _sttReady = true;
      t.done('ready=$_sttReady');
    } finally {
      _initInProgress = false;
    }
  }

  void _pushPreRoll(Uint8List chunk) {
    final copy = Uint8List.fromList(chunk);
    _preRollFrames.addLast(copy);
    _preRollBytes += copy.length;

    while (_preRollFrames.length > _maxPreRollFrames) {
      final removed = _preRollFrames.removeFirst();
      _preRollBytes -= removed.length;
    }
  }

  List<Uint8List> _snapshotPreRollFrames() {
    return _preRollFrames.map((e) => Uint8List.fromList(e)).toList();
  }

  Future<void> _beginSttSession(List<Uint8List> seedFrames) async {
    if (_sttSessionActive || _sessionStarting) return;
    if (_sessionStopping) {
      _log('Skip begin session because stop is in progress');
      return;
    }

    _sessionStarting = true;
    final t = PerfTimer('main.beginUtterance');

    try {
      await _ensureSttInit();

      if (!running) return;

      await stt.start();
      _sttSessionActive = true;

      _pcmBuf.clear();

      int seedBytes = 0;
      for (final frame in seedFrames) {
        _pcmBuf.add(frame);
        seedBytes += frame.length;
      }

      if (_pendingStartBuf.length > 0) {
        _pcmBuf.add(_pendingStartBuf.takeBytes());
      }

      _log('STT session started seedBytes=$seedBytes totalBuffered=${_pcmBuf.length}');
      unawaited(_drainPcm());
      t.done('buffered=${_pcmBuf.length}');
    } catch (e) {
      _log('Failed to begin STT session: $e');
    } finally {
      _sessionStarting = false;
    }
  }

  Future<void> _drainPcm() async {
    if (_draining) return;
    if (!_sttSessionActive) return;

    _draining = true;
    final t = PerfTimer('main.drainPcm');

    try {
      while (_sttSessionActive && _pcmBuf.length >= _sendChunkBytes) {
        final bytes = _pcmBuf.takeBytes();

        int off = 0;
        while (_sttSessionActive && off + _sendChunkBytes <= bytes.length) {
          final chunk = bytes.sublist(off, off + _sendChunkBytes);

          final pushTimer = PerfTimer('main.pushChunk');
          final ok = await stt.pushPcmBytes(chunk);
          pushTimer.done('ok=$ok bytes=${chunk.length}');

          if (!ok) {
            _log('Native rejected PCM push; stopping drain');
            break;
          }

          off += _sendChunkBytes;
          _chunksSent++;
          _bytesSent += chunk.length;

          if (_chunksSent % 10 == 1) {
            _log('Sent PCM chunk #$_chunksSent bytes=${chunk.length}');
          }
        }

        if (off < bytes.length) {
          _pcmBuf.add(bytes.sublist(off));
        }
      }
    } finally {
      _draining = false;
      t.done('bufferNow=${_pcmBuf.length}');

      if (_sttSessionActive && _pcmBuf.length >= _sendChunkBytes) {
        unawaited(_drainPcm());
      }
    }
  }

  Future<void> _flushRemainingPcm() async {
    while (_draining) {
      await Future.delayed(const Duration(milliseconds: 10));
    }

    while (_sttSessionActive && _pcmBuf.length > 0) {
      final bytes = _pcmBuf.takeBytes();

      int off = 0;
      while (_sttSessionActive && off < bytes.length) {
        final end = min(off + _sendChunkBytes, bytes.length);
        final chunk = bytes.sublist(off, end);

        final pushTimer = PerfTimer('main.flushChunk');
        final ok = await stt.pushPcmBytes(chunk);
        pushTimer.done('ok=$ok bytes=${chunk.length}');

        if (!ok) {
          _log('Native rejected flush chunk');
          return;
        }

        off = end;
      }
    }
  }

  Future<void> _endSttSession() async {
    if (_sessionStopping) return;

    _sessionStopping = true;
    final t = PerfTimer('main.endUtterance');

    try {
      while (_sessionStarting) {
        await Future.delayed(const Duration(milliseconds: 10));
      }

      if (!_sttSessionActive) return;

      _sttSessionActive = false;

      await _flushRemainingPcm();

      final flushText = await stt.flushDecode();
      _log('flushDecode returned len=${flushText.length} text="$flushText"');

      await Future.delayed(const Duration(milliseconds: 150));

      await stt.stop();

      _pcmBuf.clear();
      _pendingStartBuf.clear();

      t.done();
    } catch (e) {
      _log('Failed to end STT session: $e');
    } finally {
      _sessionStopping = false;
    }
  }

  void _handleMicChunk(Uint8List chunk) {
    _micChunkCount++;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final r = _fastRms16(chunk);
    _rmsSmooth = 0.85 * _rmsSmooth + 0.15 * r;

    if (mounted) {
      setState(() => rms = _rmsSmooth);
    }

    _pushPreRoll(chunk);

    final isVoice = r >= (_utteranceOpen ? _speechKeepRms : _speechStartRms);
    if (isVoice) {
      _lastAboveThresholdMs = nowMs;
    }

    if (!_utteranceOpen && isVoice) {
      _utteranceOpen = true;
      _pendingStartBuf.clear();

      if (mounted) {
        setState(() => partial = '');
      }

      final seedFrames = _snapshotPreRollFrames();
      _log(
        'Speech start rms=${r.toStringAsFixed(4)} '
        'seedFrames=${seedFrames.length}',
      );
      unawaited(_beginSttSession(seedFrames));
      return;
    }

    if (_utteranceOpen) {
      if (_sttSessionActive) {
        _pcmBuf.add(chunk);
        unawaited(_drainPcm());
      } else if (_sessionStarting) {
        _pendingStartBuf.add(chunk);
      } else if (!_sessionStopping) {
        _pendingStartBuf.add(chunk);
        final seedFrames = _snapshotPreRollFrames();
        _log('Recovering missing STT session during open utterance');
        unawaited(_beginSttSession(seedFrames));
      }

      final silenceMs = nowMs - _lastAboveThresholdMs;
      if (silenceMs >= _silenceMsToEnd) {
        _utteranceOpen = false;
        _log('Speech end after $silenceMs ms silence');
        unawaited(_endSttSession());
      }
    }

    if (_micChunkCount % 20 == 1) {
      _log(
        'Mic chunk #$_micChunkCount bytes=${chunk.length} '
        'rms=${r.toStringAsFixed(4)} smooth=${_rmsSmooth.toStringAsFixed(4)} '
        'utteranceOpen=$_utteranceOpen sttActive=$_sttSessionActive '
        'pcmBuf=${_pcmBuf.length}',
      );
    }
  }

  Future<void> _start() async {
    final total = PerfTimer('main.startTotal');

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _log('Microphone permission denied');
      return;
    }

    await _ensureSttInit();
    if (!mounted) return;

    _utteranceOpen = false;
    _sttSessionActive = false;
    _sessionStarting = false;
    _sessionStopping = false;
    _lastAboveThresholdMs = 0;
    _rmsSmooth = 0.0;
    _pcmBuf.clear();
    _pendingStartBuf.clear();
    _preRollFrames.clear();
    _preRollBytes = 0;
    _micChunkCount = 0;
    _chunksSent = 0;
    _bytesSent = 0;
    _partialCount = 0;
    _finalCount = 0;

    setState(() {
      running = true;
      rms = 0.0;
      partial = '';
    });

    await _micSub?.cancel();
    _micSub = mic.stream.listen(
      _handleMicChunk,
      onError: (Object e, StackTrace st) {
        _log('Mic stream error: $e');
      },
      onDone: () {
        _log('Mic stream closed');
      },
      cancelOnError: false,
    );

    await mic.start(sampleRate: 16000, numChannels: 1);
    total.done();
  }

  Future<void> _stop() async {
    final total = PerfTimer('main.stopTotal');

    running = false;
    _utteranceOpen = false;

    await _micSub?.cancel();
    _micSub = null;

    if (_sttSessionActive || _sessionStarting) {
      await _endSttSession();
    }

    await mic.stop();

    _pcmBuf.clear();
    _pendingStartBuf.clear();
    _preRollFrames.clear();
    _preRollBytes = 0;
    _rmsSmooth = 0.0;

    if (!mounted) return;

    setState(() {
      rms = 0.0;
      partial = '';
    });

    total.done(
      'micChunks=$_micChunkCount partials=$_partialCount '
      'finals=$_finalCount chunksSent=$_chunksSent bytesSent=$_bytesSent',
    );
  }

  String get _statusText {
    if (!running) return 'Idle';
    if (_sessionStopping) return 'Finishing utterance';
    if (_sessionStarting) return 'Starting utterance';
    if (_utteranceOpen) return 'Speech detected';
    return 'Listening';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offline Realtime STT')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  partial.isEmpty ? "(partial transcript appears here)" : partial,
                  style: const TextStyle(fontSize: 22),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('Status: $_statusText'),
            const SizedBox(height: 4),
            Text("Mic level (RMS): ${rms.toStringAsFixed(3)}"),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: running ? null : _start,
                    child: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: running ? _stop : null,
                    child: const Text('Stop'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Final segments:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: finals.length,
                itemBuilder: (_, i) => ListTile(title: Text(finals[i])),
              ),
            ),
          ],
        ),
      ),
    );
  }
}