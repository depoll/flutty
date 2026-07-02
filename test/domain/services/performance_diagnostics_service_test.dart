import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/performance_diagnostics_service.dart';

class _RecordingLogger implements DiagnosticsLogger {
  final events =
      <({String category, String message, Map<String, Object?> f})>[];

  @override
  void debug(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => events.add((category: category, message: message, f: fields));

  @override
  void info(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => events.add((category: category, message: message, f: fields));

  @override
  void warning(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => events.add((category: category, message: message, f: fields));

  @override
  void error(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => events.add((category: category, message: message, f: fields));
}

FrameTiming _frame({required int buildMicros, required int rasterMicros}) {
  // Build runs first on the UI thread, then raster on the GPU thread.
  const vsyncStart = 0;
  const buildStart = 0;
  final buildFinish = buildStart + buildMicros;
  final rasterStart = buildFinish;
  final rasterFinish = rasterStart + rasterMicros;
  return FrameTiming(
    vsyncStart: vsyncStart,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: rasterStart,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: rasterFinish,
  );
}

void main() {
  group('PerformanceDiagnosticsService frame jank', () {
    late _RecordingLogger logger;
    late PerformanceDiagnosticsService service;

    setUp(() {
      logger = _RecordingLogger();
      service = PerformanceDiagnosticsService(logger: logger);
    });

    test('ignores frames within budget', () {
      service.handleTimingsForTesting([
        _frame(buildMicros: 6000, rasterMicros: 5000),
      ]);
      expect(logger.events, isEmpty);
    });

    test('flags a UI-thread bound janky frame', () {
      service.handleTimingsForTesting([
        _frame(buildMicros: 1200 * 1000, rasterMicros: 4000),
      ]);
      expect(logger.events, hasLength(1));
      final event = logger.events.single;
      expect(event.category, 'perf.frame');
      expect(event.message, 'jank');
      expect(event.f['bound'], 'ui');
      expect(event.f['buildMs'], 1200);
    });

    test('flags a raster-thread bound janky frame', () {
      service.handleTimingsForTesting([
        _frame(buildMicros: 3000, rasterMicros: 900 * 1000),
      ]);
      expect(logger.events, hasLength(1));
      expect(logger.events.single.f['bound'], 'raster');
      expect(logger.events.single.f['rasterMs'], 900);
    });
  });
}
