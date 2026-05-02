/// Performance measurement helpers for Flutter widget tests.
///
/// Provides [RebuildTracker] for counting widget rebuilds and
/// [FrameTimingCollector] for capturing [FrameTiming] data during test runs.
///
/// Example – counting rebuilds:
/// ```dart
/// final count = RebuildCount();
/// await tester.pumpWidget(
///   RebuildTracker(counter: count, child: const MyWidget()),
/// );
/// expect(count.count, 1); // one initial build
/// ```
///
/// Example – collecting frame timings:
/// ```dart
/// final collector = FrameTimingCollector()..start();
/// await tester.pumpWidget(const MyWidget());
/// await tester.pumpAndSettle();
/// collector.stop();
/// debugPrint('avg build: ${collector.averageBuildDuration.inMicroseconds}µs');
/// ```
///
/// Example – one-shot measurement:
/// ```dart
/// final result = await measureRebuilds(
///   tester: tester,
///   scenarioName: 'home_initial',
///   wrapper: (child) => ProviderScope(child: child),
///   child: const HomeScreen(),
/// );
/// expect(result.rebuildCount, 1);
/// result.printSummary();
/// ```
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mutable counter used with [RebuildTracker] to record widget rebuild events.
///
/// Create one instance per scenario, pass it to [RebuildTracker], and inspect
/// [count] after pumping to verify rebuild behaviour.
class RebuildCount {
  /// The number of times [RebuildTracker.build] has been invoked.
  int count = 0;

  /// Resets [count] to zero.
  void reset() => count = 0;
}

/// Transparent widget that increments [counter] each time [build] is called.
///
/// Wrap any widget under test to measure how many times it is rebuilt:
///
/// ```dart
/// final count = RebuildCount();
/// await tester.pumpWidget(
///   RebuildTracker(counter: count, child: const MyWidget()),
/// );
/// expect(count.count, 1);
/// ```
class RebuildTracker extends StatelessWidget {
  /// Creates a [RebuildTracker].
  const RebuildTracker({required this.counter, required this.child, super.key});

  /// Accumulates rebuild events for this widget's subtree.
  final RebuildCount counter;

  /// The widget whose build invocations are counted.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    counter.count += 1;
    return child;
  }
}

/// Collects [FrameTiming] data emitted by [WidgetsBinding] during a test.
///
/// Call [start] before pumping widgets and [stop] when measurement ends.
///
/// > **Note**: In [AutomatedTestWidgetsFlutterBinding] (the default for
/// > `flutter test`), frame timings are synthetic and may not represent real
/// > GPU / raster durations. Run tests with `flutter test --profile` (or via
/// > `scripts/run_perf_benchmarks.sh`) for more meaningful build-phase data.
class FrameTimingCollector {
  final List<FrameTiming> _timings = [];

  // Nullable so [stop] is safe before [start].
  TimingsCallback? _callback;

  /// The frame timings recorded since the last [start] call.
  List<FrameTiming> get timings => List.unmodifiable(_timings);

  void _handleTimings(List<FrameTiming> incoming) => _timings.addAll(incoming);

  /// Begins collecting [FrameTiming] events from [WidgetsBinding].
  ///
  /// Clears any timings left from a previous run.
  void start() {
    _timings.clear();
    _callback = _handleTimings;
    WidgetsBinding.instance.addTimingsCallback(_callback!);
  }

  /// Stops collecting and removes the timing callback.
  ///
  /// Safe to call even when [start] has not been called.
  void stop() {
    final cb = _callback;
    if (cb == null) return;
    WidgetsBinding.instance.removeTimingsCallback(cb);
    _callback = null;
  }

  /// Sum of [FrameTiming.buildDuration] across all recorded frames.
  Duration get totalBuildDuration =>
      timings.fold(Duration.zero, (acc, t) => acc + t.buildDuration);

  /// Mean [FrameTiming.buildDuration] per frame, or [Duration.zero] if no
  /// frames were recorded.
  Duration get averageBuildDuration {
    final frames = timings;
    if (frames.isEmpty) return Duration.zero;
    return totalBuildDuration ~/ frames.length;
  }
}

/// Snapshot result from a single [measureRebuilds] call.
@immutable
class PerfResult {
  /// Creates a [PerfResult].
  const PerfResult({
    required this.scenarioName,
    required this.rebuildCount,
    required this.frameCount,
    required this.totalBuildDuration,
  });

  /// Human-readable label for the measured scenario.
  final String scenarioName;

  /// Total number of [RebuildTracker] build invocations recorded.
  final int rebuildCount;

  /// Number of [FrameTiming] events captured.
  final int frameCount;

  /// Sum of [FrameTiming.buildDuration] across all captured frames.
  final Duration totalBuildDuration;

  /// Mean build duration per frame, or [Duration.zero] when [frameCount] is 0.
  Duration get averageBuildDuration {
    if (frameCount == 0) return Duration.zero;
    return totalBuildDuration ~/ frameCount;
  }

  /// Emits a human-readable summary via [debugPrint].
  ///
  /// Output is suppressed in release builds via [debugPrint].
  void printSummary() => debugPrint(
    'PerfResult [$scenarioName]: '
    '$rebuildCount rebuild(s), '
    '$frameCount frame(s), '
    '${averageBuildDuration.inMicroseconds}µs avg frame-build',
  );

  @override
  String toString() =>
      'PerfResult($scenarioName: $rebuildCount rebuild(s), '
      '$frameCount frame(s), '
      '${averageBuildDuration.inMicroseconds}µs avg build)';
}

/// Pumps [child] inside [wrapper] and returns a [PerfResult] measuring rebuild
/// count and frame timings.
///
/// [wrapper] receives a [RebuildTracker]-wrapped [child], letting you inject
/// ancestors like [ProviderScope] or [MaterialApp]:
///
/// ```dart
/// final result = await measureRebuilds(
///   tester: tester,
///   scenarioName: 'hosts_list_initial',
///   wrapper: (child) => ProviderScope(child: child),
///   child: const HostsScreen(),
/// );
/// expect(result.rebuildCount, 1);
/// result.printSummary();
/// ```
Future<PerfResult> measureRebuilds({
  required WidgetTester tester,
  required String scenarioName,
  required Widget Function(Widget child) wrapper,
  required Widget child,
}) async {
  final count = RebuildCount();
  final collector = FrameTimingCollector()..start();
  await tester.pumpWidget(
    wrapper(RebuildTracker(counter: count, child: child)),
  );
  await tester.pumpAndSettle();
  collector.stop();
  return PerfResult(
    scenarioName: scenarioName,
    rebuildCount: count.count,
    frameCount: collector.timings.length,
    totalBuildDuration: collector.totalBuildDuration,
  );
}
