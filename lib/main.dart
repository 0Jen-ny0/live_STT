import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'stt/whisper_stt.dart';

void main() => runApp(const OfflineSttDemo());

class OfflineSttDemo extends StatelessWidget {
  const OfflineSttDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live STT Demo',
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
  final WhisperStt _stt = WhisperStt();

  StreamSubscription<Map<dynamic, dynamic>>? _sub;

  String _status = 'Idle';
  String _stableText = '';
  String _partialText = '';
  bool _isReady = false;
  bool _isStreaming = false;

  @override
  void initState() {
    super.initState();
    _bindEvents();
    _init();
  }

  void _bindEvents() {
    _sub = _stt.events.listen((event) {
      final type = event['type'] as String? ?? '';

      if (type == 'status') {
        setState(() {
          _status = event['status'] as String? ?? 'Unknown';
        });
      } else if (type == 'transcript') {
        setState(() {
          _stableText = event['stableText'] as String? ?? '';
          _partialText = event['partialText'] as String? ?? '';
        });
      } else if (type == 'error') {
        setState(() {
          _status = 'Error: ${event['message'] ?? 'unknown'}';
          _isStreaming = false;
        });
      }
    });
  }

  Future<void> _init() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      setState(() {
        _status = 'Microphone permission denied';
      });
      return;
    }

    try {
      await _stt.initModel(
        assetPath: 'assets/models/ggml-tiny.en.bin',
        threads: 4,
      );

      setState(() {
        _isReady = true;
        _status = 'Ready';
      });
    } catch (e) {
      setState(() {
        _status = 'Init failed: $e';
      });
    }
  }

  Future<void> _start() async {
    try {
      await _stt.startStreaming(
        stepMs: 400,
        windowMs: 5000,
        keepMs: 200,
        language: 'en',
        audioCtx: 512,
      );

      setState(() {
        _isStreaming = true;
        _stableText = '';
        _partialText = '';
      });
    } catch (e) {
      setState(() {
        _status = 'Start failed: $e';
        _isStreaming = false;
      });
    }
  }

  Future<void> _stop() async {
    try {
      await _stt.stopStreaming();
    } finally {
      setState(() {
        _isStreaming = false;
        _status = 'Idle';
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final liveText = [
      _stableText.trim(),
      _partialText.trim(),
    ].where((s) => s.isNotEmpty).join(' ');

    return Scaffold(
      appBar: AppBar(title: const Text('Live STT')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Card(
              child: ListTile(
                title: const Text('Status'),
                subtitle: Text(_status),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SingleChildScrollView(
                      child: Text(
                        liveText.isEmpty ? 'Transcript will appear here...' : liveText,
                        style: const TextStyle(fontSize: 22, height: 1.4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: (_isReady && !_isStreaming) ? _start : null,
                    child: const Text('Start streaming'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isStreaming ? _stop : null,
                    child: const Text('Stop'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}