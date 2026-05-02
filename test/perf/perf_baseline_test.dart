// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/perf_helpers.dart';

void main() {
  group('RebuildCount', () {
    test('starts at zero', () {
      expect(RebuildCount().count, 0);
    });

    test('reset returns count to zero', () {
      final count = RebuildCount()
        ..count = 5
        ..reset();
      expect(count.count, 0);
    });
  });

  group('RebuildTracker', () {
    testWidgets('counts initial build', (tester) async {
      final count = RebuildCount();
      await tester.pumpWidget(
        RebuildTracker(counter: count, child: const SizedBox()),
      );
      expect(count.count, 1);
    });

    testWidgets('counts each rebuild triggered by ancestor state', (
      tester,
    ) async {
      final count = RebuildCount();
      final notifier = ValueNotifier<int>(0);
      addTearDown(notifier.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ValueListenableBuilder<int>(
            valueListenable: notifier,
            builder: (_, value, _) =>
                RebuildTracker(counter: count, child: Text('$value')),
          ),
        ),
      );
      expect(count.count, 1);

      notifier.value = 1;
      await tester.pump();
      expect(count.count, 2);

      notifier.value = 2;
      await tester.pump();
      expect(count.count, 3);
    });

    testWidgets('const child does not add extra rebuilds', (tester) async {
      final count = RebuildCount();
      final notifier = ValueNotifier<int>(0);
      addTearDown(notifier.dispose);

      // Tracker is NOT inside the ValueListenableBuilder – its parent does not
      // rebuild, so count should stay at 1.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RebuildTracker(
            counter: count,
            child: ValueListenableBuilder<int>(
              valueListenable: notifier,
              builder: (_, value, _) => Text('$value'),
            ),
          ),
        ),
      );
      expect(count.count, 1);

      notifier.value = 99;
      await tester.pump();
      expect(count.count, 1);
    });
  });

  group('FrameTimingCollector', () {
    testWidgets('returns an unmodifiable list from timings', (tester) async {
      final collector = FrameTimingCollector()..start();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      collector.stop();

      final list = collector.timings;
      expect(list, isA<List<FrameTiming>>());
      // Mutation should throw on the unmodifiable view.
      expect(list.clear, throwsUnsupportedError);
    });

    testWidgets('averageBuildDuration is Duration.zero when no frames', (
      _,
    ) async {
      // Do not call start() – timings will be empty.
      final collector = FrameTimingCollector();
      expect(collector.averageBuildDuration, Duration.zero);
    });

    testWidgets('stop is safe before start', (_) async {
      final collector = FrameTimingCollector();
      expect(collector.stop, returnsNormally);
    });

    testWidgets('stop after start removes the callback', (tester) async {
      final collector = FrameTimingCollector()..start();
      await tester.pumpWidget(const SizedBox());
      collector.stop();

      // A second stop should be a no-op (callback already removed).
      expect(collector.stop, returnsNormally);
    });
  });

  group('PerfResult', () {
    test('averageBuildDuration is zero when frameCount is zero', () {
      const result = PerfResult(
        scenarioName: 'empty',
        rebuildCount: 0,
        frameCount: 0,
        totalBuildDuration: Duration.zero,
      );
      expect(result.averageBuildDuration, Duration.zero);
    });

    test('averageBuildDuration divides total by frame count', () {
      const result = PerfResult(
        scenarioName: 'timed',
        rebuildCount: 3,
        frameCount: 4,
        totalBuildDuration: Duration(microseconds: 800),
      );
      expect(result.averageBuildDuration, const Duration(microseconds: 200));
    });

    test('toString contains scenario name and rebuild count', () {
      const result = PerfResult(
        scenarioName: 'my_scenario',
        rebuildCount: 7,
        frameCount: 0,
        totalBuildDuration: Duration.zero,
      );
      expect(result.toString(), contains('my_scenario'));
      expect(result.toString(), contains('7'));
    });
  });

  group('measureRebuilds', () {
    testWidgets('returns PerfResult with at least one rebuild', (tester) async {
      final result = await measureRebuilds(
        tester: tester,
        scenarioName: 'sized_box_baseline',
        wrapper: (child) => child,
        child: const SizedBox(),
      );
      expect(result.rebuildCount, greaterThanOrEqualTo(1));
      expect(result.scenarioName, 'sized_box_baseline');
    });

    testWidgets('counts multiple rebuilds during scenario', (tester) async {
      final count = RebuildCount();
      final notifier = ValueNotifier<int>(0);
      addTearDown(notifier.dispose);

      final collector = FrameTimingCollector()..start();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ValueListenableBuilder<int>(
            valueListenable: notifier,
            builder: (_, value, _) =>
                RebuildTracker(counter: count, child: Text('$value')),
          ),
        ),
      );

      notifier.value = 1;
      await tester.pump();
      notifier.value = 2;
      await tester.pump();

      collector.stop();

      final result = PerfResult(
        scenarioName: 'notifier_three_frames',
        rebuildCount: count.count,
        frameCount: collector.timings.length,
        totalBuildDuration: collector.totalBuildDuration,
      );

      expect(result.rebuildCount, 3);
    });

    testWidgets('wrapper is applied around RebuildTracker', (tester) async {
      var wrapperCalled = false;
      final result = await measureRebuilds(
        tester: tester,
        scenarioName: 'wrapper_check',
        wrapper: (child) {
          wrapperCalled = true;
          return child;
        },
        child: const SizedBox(),
      );
      expect(wrapperCalled, isTrue);
      expect(result.rebuildCount, greaterThanOrEqualTo(1));
    });
  });
}
