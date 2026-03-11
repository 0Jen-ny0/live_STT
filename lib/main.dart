import 'dart:async';
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

  String partial = "";
  final List<String> finals = [];
  bool running = false;

  double rms = 0.0;
  double _rmsSmooth = 0.0;

  final BytesBuilder _pcmBuf = BytesBuilder(copy: false);
  bool _draining = false;

  bool _sttReady = false;
  bool _initInProgress = false;

  static const int _sendChunkBytes = 3200;

  int _micChunkCount = 0;
  int _partialCount = 0;
  int _finalCount = 0;
  int _drainCalls = 0;
  int _chunksSent = 0;
  int _bytesSent = 0;

  void _log(String msg) {
    debugPrint('[MainSTT] $msg');
  }

  @override
  void initState() {
    super.initState();
    _log('initState()');

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
      _log('Final #$_finalCount len=${tt.length}');

      if (!mounted) return;
      setState(() => finals.insert(0, tt));
    });
  }

  @override
  void dispose() {
    _log(
      'dispose() micChunks=$_micChunkCount partials=$_partialCount '
      'finals=$_finalCount drainCalls=$_drainCalls '
      'chunksSent=$_chunksSent bytesSent=$_bytesSent',
    );

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
    if (n <= 0) return 0;

    const step = 6;
    double sumSq = 0;
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
    _log('_ensureSttInit() ready=$_sttReady inProgress=$_initInProgress');

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

  Future<void> _drainPcm() async {
    if (_draining) return;

    _draining = true;
    _drainCalls++;
    final t = PerfTimer('main.drainPcm');

    try {
      bool keepGoing = true;

      while (keepGoing && running && _pcmBuf.length >= _sendChunkBytes) {
        final bytes = _pcmBuf.takeBytes();

        int off = 0;
        int sentThisDrain = 0;

        while (keepGoing && off + _sendChunkBytes <= bytes.length) {
          final chunk = bytes.sublist(off, off + _sendChunkBytes);

          final pushTimer = PerfTimer('main.pushChunk');
          final ok = await stt.pushPcmBytes(chunk);
          pushTimer.done('ok=$ok bytes=${chunk.length}');

          if (!ok) {
            _log('Native rejected PCM push; stopping drain');
            keepGoing = false;
            break;
          }

          off += _sendChunkBytes;
          sentThisDrain++;
          _chunksSent++;
          _bytesSent += chunk.length;

          if (_chunksSent % 10 == 1) {
            _log(
              'Sent PCM chunk #$_chunksSent bytes=${chunk.length} '
              'bufferApprox=${_pcmBuf.length}',
            );
          }
        }

        if (off < bytes.length) {
          _pcmBuf.add(bytes.sublist(off));
        }

        if (sentThisDrain > 0) {
          _log(
            'Drain call #$_drainCalls sent $sentThisDrain chunk(s), '
            'leftoverBuffer=${_pcmBuf.length} bytes',
          );
        }
      }
    } finally {
      _draining = false;
      t.done('bufferNow=${_pcmBuf.length}');

      if (running && _pcmBuf.length >= _sendChunkBytes) {
        unawaited(_drainPcm());
      }
    }
  }

  Future<void> _start() async {
    _log('_start() pressed');
    final total = PerfTimer('main.startTotal');

    final permTimer = PerfTimer('main.permission');
    final status = await Permission.microphone.request();
    permTimer.done('status=$status');

    if (!status.isGranted) {
      _log('Microphone permission denied');
      return;
    }

    await _ensureSttInit();
    if (!mounted) return;

    _micChunkCount = 0;
    _partialCount = 0;
    _finalCount = 0;
    _drainCalls = 0;
    _chunksSent = 0;
    _bytesSent = 0;
    _pcmBuf.clear();
    _rmsSmooth = 0.0;

    setState(() => running = true);

    final sttStart = PerfTimer('main.sttStart');
    await stt.start();
    sttStart.done();

    await _micSub?.cancel();
    _micSub = mic.stream.listen(
      (chunk) {
        _micChunkCount++;

        final r = _fastRms16(chunk);
        _rmsSmooth = 0.85 * _rmsSmooth + 0.15 * r;

        if (mounted) {
          setState(() => rms = _rmsSmooth);
        }

        _pcmBuf.add(chunk);

        if (_micChunkCount % 20 == 1) {
          _log(
            'Mic chunk #$_micChunkCount bytes=${chunk.length} '
            'rms=${r.toStringAsFixed(4)} smooth=${_rmsSmooth.toStringAsFixed(4)} '
            'pcmBuffer=${_pcmBuf.length}',
          );
        }

        unawaited(_drainPcm());
      },
      onError: (Object e, StackTrace st) {
        _log('Mic stream error: $e');
      },
      onDone: () {
        _log('Mic stream closed');
      },
      cancelOnError: false,
    );

    final micStart = PerfTimer('main.micStart');
    await mic.start(sampleRate: 16000, numChannels: 1);
    micStart.done();

    total.done();
  }

  Future<void> _stop() async {
    _log('_stop() pressed');
    final total = PerfTimer('main.stopTotal');

    await _micSub?.cancel();
    _micSub = null;
    _log('Mic subscription cancelled');

    final micStop = PerfTimer('main.micStop');
    await mic.stop();
    micStop.done();

    if (_pcmBuf.length > 0) {
      final leftover = _pcmBuf.length;
      final flushT = PerfTimer('main.flushLeftover');
      try {
        await stt.pushPcmBytes(_pcmBuf.takeBytes());
        flushT.done('bytes=$leftover');
      } catch (e) {
        _log('Failed to flush leftover PCM: $e');
      }
    } else {
      _log('No leftover PCM to flush');
    }

    final sttStop = PerfTimer('main.sttStop');
    await stt.stop();
    sttStop.done();

    _pcmBuf.clear();
    _rmsSmooth = 0.0;

    if (!mounted) return;

    setState(() {
      running = false;
      rms = 0.0;
      partial = "";
    });

    total.done(
      'micChunks=$_micChunkCount partials=$_partialCount '
      'finals=$_finalCount chunksSent=$_chunksSent bytesSent=$_bytesSent',
    );
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
            Text("Mic level (RMS): ${rms.toStringAsFixed(3)}"),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: running ? null : _start,
                    child: const Text("Start"),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: running ? _stop : null,
                    child: const Text("Stop"),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text("Final segments:", style: TextStyle(fontWeight: FontWeight.bold)),
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