import 'dart:typed_data';

abstract class OfflineStt {
  Stream<String> get partial;
  Stream<String> get finalText;

  Future<void> init();
  Future<void> start();
  Future<void> stop();

  /// Push little-endian PCM16 audio bytes (mono) to native.
  Future<void> pushPcmBytes(Uint8List pcm16leBytes);
}