import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/telemetry_service.dart';

void main() {
  group('TelemetryService', () {
    test('does not send analytics until collection is enabled', () async {
      final analytics = _FakeAnalyticsClient();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: false,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: _FakeCrashReporter(),
      );

      await service.logFeatureOpened(feature: 'terminal');
      await service.setCollectionEnabled(enabled: true);
      await service.logFeatureOpened(feature: 'terminal');

      expect(analytics.events, hasLength(1));
      expect(analytics.events.single.name, 'feature_opened');
      expect(analytics.events.single.parameters, {'feature': 'terminal'});
    });

    test('disabling collection clears analytics data', () async {
      final analytics = _FakeAnalyticsClient();
      final crashReporter = _FakeCrashReporter();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: crashReporter,
      );

      await service.setCollectionEnabled(enabled: false);

      expect(analytics.collectionEnabled, isFalse);
      expect(analytics.resetCount, 1);
      expect(crashReporter.collectionEnabled, isFalse);
      expect(crashReporter.deleteUnsentReportsCount, 1);
    });

    test('sanitizes event names and parameter values', () async {
      final analytics = _FakeAnalyticsClient();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: analytics,
        crashReporter: _FakeCrashReporter(),
      );

      await service.logFeatureOpened(feature: 'Terminal Screen!');

      expect(analytics.events.single.parameters, {
        'feature': 'terminal_screen',
      });
    });

    test('records sanitized crash errors when collection is enabled', () async {
      final crashReporter = _FakeCrashReporter();
      final service = TelemetryService(
        status: TelemetryServiceStatus.ready,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        analyticsClient: _FakeAnalyticsClient(),
        crashReporter: crashReporter,
      );

      await service.recordError(
        ArgumentError('host secret.example.com'),
        StackTrace.current,
        fatal: true,
      );

      expect(crashReporter.recordedErrors, hasLength(1));
      expect(
        crashReporter.recordedErrors.single.error.toString(),
        'ArgumentError',
      );
      expect(
        crashReporter.recordedErrors.single.error.toString(),
        isNot(contains('secret.example.com')),
      );
      expect(crashReporter.recordedErrors.single.fatal, isTrue);
    });

    test('does not record crashes when unavailable', () async {
      final crashReporter = _FakeCrashReporter();
      final service = TelemetryService(
        status: TelemetryServiceStatus.disabledByBuild,
        collectionEnabled: true,
        diagnosticsLogger: const NoopDiagnosticsLogger(),
        crashReporter: crashReporter,
      );

      await service.recordFlutterError(
        FlutterErrorDetails(exception: StateError('private details')),
      );

      expect(crashReporter.recordedFlutterErrors, isEmpty);
    });
  });

  group('isFirebaseTelemetrySupportedPlatform', () {
    test('supports Android and iOS only', () {
      expect(
        isFirebaseTelemetrySupportedPlatform(
          isWeb: false,
          targetPlatform: TargetPlatform.android,
        ),
        isTrue,
      );
      expect(
        isFirebaseTelemetrySupportedPlatform(
          isWeb: false,
          targetPlatform: TargetPlatform.iOS,
        ),
        isTrue,
      );
      expect(
        isFirebaseTelemetrySupportedPlatform(
          isWeb: false,
          targetPlatform: TargetPlatform.macOS,
        ),
        isFalse,
      );
      expect(
        isFirebaseTelemetrySupportedPlatform(
          isWeb: true,
          targetPlatform: TargetPlatform.android,
        ),
        isFalse,
      );
    });
  });

  group('TelemetryOptInPromptNotifier', () {
    test('records launch count for delayed prompt eligibility', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = _createTelemetryContainer(db: db);
      addTearDown(container.dispose);
      addTearDown(db.close);

      final notifier = container.read(
        telemetryOptInPromptNotifierProvider.notifier,
      );
      await notifier.recordAppLaunch();
      await notifier.recordAppLaunch();
      await notifier.recordAppLaunch();

      final state = container.read(telemetryOptInPromptNotifierProvider);
      expect(
        state.appLaunchCount,
        TelemetryOptInPromptNotifier.minimumLaunchCountForPrompt,
      );
      expect(state.choice, TelemetryOptInPromptChoice.notShown);
      expect(
        await SettingsService(db).getInt(SettingKeys.telemetryAppLaunchCount),
        TelemetryOptInPromptNotifier.minimumLaunchCountForPrompt,
      );
    });

    test('accept enables collection and resolves prompt', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final analytics = _FakeAnalyticsClient();
      final crashReporter = _FakeCrashReporter();
      final container = _createTelemetryContainer(
        db: db,
        telemetryService: TelemetryService(
          status: TelemetryServiceStatus.ready,
          collectionEnabled: false,
          diagnosticsLogger: const NoopDiagnosticsLogger(),
          analyticsClient: analytics,
          crashReporter: crashReporter,
        ),
      );
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container
          .read(telemetryOptInPromptNotifierProvider.notifier)
          .accept();

      final settings = SettingsService(db);
      expect(
        container.read(telemetryOptInPromptNotifierProvider).choice,
        TelemetryOptInPromptChoice.accepted,
      );
      expect(await settings.getBool(SettingKeys.telemetryCollection), isTrue);
      expect(
        await settings.getString(SettingKeys.telemetryOptInPromptState),
        TelemetryOptInPromptChoice.accepted.name,
      );
      expect(analytics.collectionEnabled, isTrue);
      expect(crashReporter.collectionEnabled, isTrue);
    });

    test('dismiss resolves prompt without enabling collection', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final container = _createTelemetryContainer(db: db);
      addTearDown(container.dispose);
      addTearDown(db.close);

      await container
          .read(telemetryOptInPromptNotifierProvider.notifier)
          .dismiss();

      final settings = SettingsService(db);
      expect(
        container.read(telemetryOptInPromptNotifierProvider).choice,
        TelemetryOptInPromptChoice.dismissed,
      );
      expect(await settings.getBool(SettingKeys.telemetryCollection), isFalse);
      expect(
        await settings.getString(SettingKeys.telemetryOptInPromptState),
        TelemetryOptInPromptChoice.dismissed.name,
      );
    });
  });
}

ProviderContainer _createTelemetryContainer({
  required AppDatabase db,
  TelemetryService? telemetryService,
}) => ProviderContainer(
  overrides: [
    databaseProvider.overrideWithValue(db),
    telemetryServiceProvider.overrideWithValue(
      telemetryService ??
          TelemetryService(
            status: TelemetryServiceStatus.disabledByBuild,
            collectionEnabled: false,
            diagnosticsLogger: const NoopDiagnosticsLogger(),
          ),
    ),
  ],
);

class _FakeAnalyticsClient implements TelemetryAnalyticsClient {
  final List<_AnalyticsEvent> events = <_AnalyticsEvent>[];
  bool? collectionEnabled;
  int resetCount = 0;

  @override
  Future<void> logEvent({
    required String name,
    required Map<String, Object> parameters,
  }) async {
    events.add(_AnalyticsEvent(name: name, parameters: parameters));
  }

  @override
  Future<void> resetAnalyticsData() async {
    resetCount += 1;
  }

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {
    collectionEnabled = enabled;
  }
}

class _FakeCrashReporter implements TelemetryCrashReporter {
  final List<_RecordedError> recordedErrors = <_RecordedError>[];
  final List<FlutterErrorDetails> recordedFlutterErrors =
      <FlutterErrorDetails>[];
  final Map<String, Object> customKeys = <String, Object>{};
  bool? collectionEnabled;
  int deleteUnsentReportsCount = 0;

  @override
  Future<void> deleteUnsentReports() async {
    deleteUnsentReportsCount += 1;
  }

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
  Future<void> recordFlutterError(FlutterErrorDetails details) async {
    recordedFlutterErrors.add(details);
  }

  @override
  Future<void> setCollectionEnabled({required bool enabled}) async {
    collectionEnabled = enabled;
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {
    customKeys[key] = value;
  }
}

class _AnalyticsEvent {
  const _AnalyticsEvent({required this.name, required this.parameters});

  final String name;
  final Map<String, Object> parameters;
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
