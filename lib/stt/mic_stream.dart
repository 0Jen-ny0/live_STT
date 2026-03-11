import 'dart:typed_data';

@Deprecated('Not used when microphone capture is handled natively on Android.')
class MicPcmStream {
  Stream<Uint8List> get stream => const Stream<Uint8List>.empty();

  Future<void> start() async {}

  Future<void> stop() async {}
}