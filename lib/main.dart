// lib/main.dart
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

  bool _sttReady = false;
  bool _initInProgress = false;

  // ==============================
  // Speech detection / utterance capture
  // ==============================
  bool _utteranceOpen = false;
  int _lastAboveThresholdMs = 0;
  int _utteranceStartMs = 0;
  final BytesBuilder _currentUtterance = BytesBuilder(copy: false);

  // ==============================
  // Pre-roll buffer so speech start is not clipped
  // ==============================
  final ListQueue<Uint8List> _preRollFrames = ListQueue<Uint8List>();

  // 20 ms @ 16 kHz mono PCM16 = 640 bytes
  static const int _frameBytes = 640;

  // 10 x 20 ms = 200 ms chunks sent to native
  static const int _sendChunkBytes = 6400;

  // Keep ~300 ms of pre-roll = 15 x 20 ms frames
  static const int _maxPreRollFrames = 15;

  // Drop extremely tiny utterances
  static const int _minUtteranceBytes = 3200; // 100 ms

  static const int _queuedSendChunkBytes = 64000; // ~1 second at 16 kHz mono PCM16

  // RMS thresholds
  static const double _speechStartRms = 0.012;
  static const double _speechKeepRms = 0.008;

  // End utterance sooner after silence
  static const int _silenceMsToEnd = 350;

  // Force-split long utterances to reduce "finishing utterance" delay
  static const int _maxUtteranceMs = 2000;

  // ==============================
  // Decode queue
  // ==============================
  final Queue<Uint8List> _utteranceQueue = Queue<Uint8List>();
  bool _processingQueue = false;
  int _utteranceCounter = 0;
  int _processedUtterances = 0;

  int _micChunkCount = 0;
  int _partialCount = 0;
  int _finalCount = 0;
  int _chunksSent = 0;
  int _bytesSent = 0;

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

    while (_preRollFrames.length > _maxPreRollFrames) {
      _preRollFrames.removeFirst();
    }
  }

  List<Uint8List> _snapshotPreRollFrames() {
    return _preRollFrames.map((e) => Uint8List.fromList(e)).toList();
  }

  void _startUtterance() {
    _utteranceOpen = true;
    _utteranceStartMs = DateTime.now().millisecondsSinceEpoch;
    _currentUtterance.clear();

    final seedFrames = _snapshotPreRollFrames();
    for (final frame in seedFrames) {
      _currentUtterance.add(frame);
    }

    _utteranceCounter++;
    _log('Speech start utterance=$_utteranceCounter seedFrames=${seedFrames.length}');

    if (mounted) {
      setState(() {
        partial = '(capturing utterance $_utteranceCounter...)';
      });
    }
  }

  void _enqueueCurrentUtterance() {
    final bytes = _currentUtterance.takeBytes();

    if (bytes.length < _minUtteranceBytes) {
      _log('Drop short utterance bytes=${bytes.length}');
      return;
    }

    _utteranceQueue.add(Uint8List.fromList(bytes));
    _log(
      'Queued utterance #${_utteranceQueue.length + _processedUtterances} '
      'bytes=${bytes.length} queueSize=${_utteranceQueue.length}',
    );

    unawaited(_processUtteranceQueue());
  }

  Future<void> _processUtteranceQueue() async {
    if (_processingQueue) return;
    _processingQueue = true;

    try {
      while (_utteranceQueue.isNotEmpty) {
        final utterance = _utteranceQueue.removeFirst();
        _processedUtterances++;

        final utteranceId = _processedUtterances;
        final utteranceSeconds = utterance.length / (2 * 16000);
        _log(
          'Processing utterance #$utteranceId '
          'bytes=${utterance.length} seconds=${utteranceSeconds.toStringAsFixed(2)}',
        );

        if (mounted) {
          setState(() {
            partial = '(processing utterance #$utteranceId...)';
          });
        }

        final startT = PerfTimer('main.decodeUtterance.start');
        await stt.start();
        startT.done('utterance=$utteranceId');

        int off = 0;
        while (off < utterance.length) {
          final end = min(off + _queuedSendChunkBytes, utterance.length);
          final chunk = utterance.sublist(off, end);

          final pushT = PerfTimer('main.pushQueuedUtteranceChunk');
          final ok = await stt.pushPcmBytes(chunk);
          pushT.done('ok=$ok bytes=${chunk.length}');

          if (!ok) {
            _log('Native rejected queued utterance chunk');
            break;
          }

          off = end;
          _chunksSent++;
          _bytesSent += chunk.length;
        }

        final flushT = PerfTimer('main.flushQueuedUtterance');
        final flushText = await stt.flushDecode();
        flushT.done('len=${flushText.length}');

        if (flushText.trim().isNotEmpty && mounted) {
          setState(() {
            partial = flushText.trim();
          });
        }

        await Future.delayed(const Duration(milliseconds: 150));

        final stopT = PerfTimer('main.decodeUtterance.stop');
        await stt.stop();
        stopT.done('utterance=$utteranceId');
      }
    } catch (e) {
      _log('Queue processing error: $e');
    } finally {
      _processingQueue = false;

      if (mounted && running && !_utteranceOpen) {
        setState(() {
          if (_utteranceQueue.isEmpty) {
            partial = '';
          }
        });
      }
    }
  }

  Future<void> _waitForQueueToFinish() async {
    while (_processingQueue || _utteranceQueue.isNotEmpty) {
      await Future.delayed(const Duration(milliseconds: 50));
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
      _startUtterance();
    }

    if (_utteranceOpen) {
      _currentUtterance.add(Uint8List.fromList(chunk));

      // Force split long utterances so final decode has less work.
      final utteranceMs = nowMs - _utteranceStartMs;
      if (utteranceMs >= _maxUtteranceMs) {
        _utteranceOpen = false;
        _log('Force split utterance at $utteranceMs ms');
        _enqueueCurrentUtterance();

        if (isVoice) {
          _startUtterance();
        }
        return;
      }

      final silenceMs = nowMs - _lastAboveThresholdMs;
      if (silenceMs >= _silenceMsToEnd) {
        _utteranceOpen = false;
        _log('Speech end after $silenceMs ms silence');
        _enqueueCurrentUtterance();
      }
    }

    if (_micChunkCount % 20 == 1) {
      _log(
        'Mic chunk #$_micChunkCount bytes=${chunk.length} '
        'rms=${r.toStringAsFixed(4)} smooth=${_rmsSmooth.toStringAsFixed(4)} '
        'utteranceOpen=$_utteranceOpen queue=${_utteranceQueue.length} '
        'processing=$_processingQueue currentBytes=${_currentUtterance.length}',
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
    _lastAboveThresholdMs = 0;
    _utteranceStartMs = 0;
    _currentUtterance.clear();
    _preRollFrames.clear();
    _utteranceQueue.clear();
    _processingQueue = false;
    _utteranceCounter = 0;
    _processedUtterances = 0;
    _rmsSmooth = 0.0;
    _micChunkCount = 0;
    _partialCount = 0;
    _finalCount = 0;
    _chunksSent = 0;
    _bytesSent = 0;

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

    await _micSub?.cancel();
    _micSub = null;

    if (_utteranceOpen) {
      _utteranceOpen = false;
      _log('Stop pressed: closing current utterance');
      _enqueueCurrentUtterance();
    }

    await mic.stop();

    if (mounted) {
      setState(() {
        partial = '(finishing queued utterances...)';
      });
    }

    await _waitForQueueToFinish();

    _currentUtterance.clear();
    _preRollFrames.clear();
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
    if (_utteranceOpen && _processingQueue) return 'Recording + decoding queue';
    if (_utteranceOpen) return 'Recording utterance';
    if (_processingQueue) return 'Decoding queued utterance';
    if (_utteranceQueue.isNotEmpty) return 'Queued utterances: ${_utteranceQueue.length}';
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
                  partial.isEmpty ? '(partial transcript appears here)' : partial,
                  style: const TextStyle(fontSize: 22),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('Status: $_statusText'),
            const SizedBox(height: 4),
            Text('Mic level (RMS): ${rms.toStringAsFixed(3)}'),
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