import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/telemetry_service.dart';
import 'package:monkeyssh/main.dart' as app_entry;

void main() {
  group('installTelemetryErrorHandlers', () {
    late FlutterExceptionHandler? originalFlutterErrorHandler;
    late ErrorCallback? originalPlatformErrorHandler;

    setUp(() {
      originalFlutterErrorHandler = FlutterError.onError;
      originalPlatformErrorHandler = PlatformDispatcher.instance.onError;
      FlutterError.onError = null;
      PlatformDispatcher.instance.onError = null;
    });

    tearDown(() {
      FlutterError.onError = originalFlutterErrorHandler;
      PlatformDispatcher.instance.onError = originalPlatformErrorHandler;
    });

    test(
      'records root isolate Dart errors as handled non-fatal reports',
      () async {
        final crashReporter = _FakeCrashReporter();
        var previousHandlerCallCount = 0;
        var previousFlutterErrorCallCount = 0;
        FlutterError.onError = (_) {
          previousFlutterErrorCallCount += 1;
        };
        PlatformDispatcher.instance.onError = (error, stackTrace) {
          previousHandlerCallCount += 1;
          FlutterError.onError!(
            FlutterErrorDetails(exception: error, stack: stackTrace),
          );
          return false;
        };
        final service = TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: true,
          diagnosticsLogger: const NoopDiagnosticsLogger(),
          crashReporter: crashReporter,
        );

        app_entry.installTelemetryErrorHandlers(service);

        final handled = PlatformDispatcher.instance.onError!(
          StateError('secret.example.com'),
          StackTrace.current,
        );
        await Future<void>.delayed(Duration.zero);

        expect(handled, isTrue);
        expect(previousHandlerCallCount, 1);
        expect(previousFlutterErrorCallCount, 1);
        expect(crashReporter.recordedErrors, hasLength(1));
        expect(
          crashReporter.recordedErrors.single.error.toString(),
          'StateError',
        );
        expect(crashReporter.recordedErrors.single.fatal, isFalse);
      },
    );
  });
}

class _FakeCrashReporter implements TelemetryCrashReporter {
  final List<_RecordedError> recordedErrors = <_RecordedError>[];

  @override
  Future<void> deleteUnsentReports() async {}

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required bool fatal,
  }) async {
    recordedErrors.add(
      _RecordedError(error: error, stackTrace: stackTrace, fatal: fatal),
    );
  }

  @override
  Future<void> recordFlutterError(FlutterErrorDetails details) async {}

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {}

  @override
  Future<void> setCustomKey(String key, Object value) async {}
}

class _RecordedError {
  const _RecordedError({
    required this.error,
    required this.stackTrace,
    required this.fatal,
  });

  final Object error;
  final StackTrace stackTrace;
  final bool fatal;
}
