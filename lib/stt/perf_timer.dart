import 'package:flutter/foundation.dart';

class PerfTimer {
  final String name;
  final Stopwatch _sw = Stopwatch()..start();

  PerfTimer(this.name);

  void checkpoint([String extra = '']) {
    final suffix = extra.isEmpty ? '' : ' $extra';
    debugPrint('[Perf] $name @ ${_sw.elapsedMilliseconds} ms$suffix');
  }

  void done([String extra = '']) {
    final suffix = extra.isEmpty ? '' : ' $extra';
    debugPrint('[Perf] $name took ${_sw.elapsedMilliseconds} ms$suffix');
  }
}