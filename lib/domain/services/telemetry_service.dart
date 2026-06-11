import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_metadata.dart';
import 'diagnostics_log_service.dart';
import 'settings_service.dart';

/// Compile-time flag that allows Firebase-backed telemetry to initialize.
const isFirebaseTelemetryBuildEnabled = bool.fromEnvironment(
  'FLUTTY_FIREBASE_ENABLED',
);

/// Current Firebase telemetry availability for this app run.
enum TelemetryServiceStatus {
  /// Firebase is initialized and can receive opted-in events.
  ready,

  /// The build did not opt in to Firebase initialization.
  disabledByBuild,

  /// Firebase telemetry is not supported on this platform.
  unsupportedPlatform,

  /// Firebase initialization failed, usually because config is missing.
  initializationFailed,
}

/// Minimal analytics client seam used by [TelemetryService].
abstract interface class TelemetryAnalyticsClient {
  /// Enables or disables analytics collection in the underlying SDK.
  Future<void> setCollectionEnabled({required bool enabled});

  /// Clears SDK analytics identifiers and local analytics data when available.
  Future<void> resetAnalyticsData();

  /// Records a single allowlisted analytics event.
  Future<void> logEvent({
    required String name,
    required Map<String, Object> parameters,
  });
}

/// Minimal crash reporter seam used by [TelemetryService].
abstract interface class TelemetryCrashReporter {
  /// Enables or disables crash report collection in the underlying SDK.
  Future<void> setCollectionEnabled({required bool enabled});

  /// Deletes locally retained crash reports that have not been uploaded.
  Future<void> deleteUnsentReports();

  /// Records a sanitized Flutter framework error.
  Future<void> recordFlutterError(FlutterErrorDetails details);

  /// Records a sanitized Dart error.
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required bool fatal,
  });

  /// Sets a primitive custom key for later crash reports.
  Future<void> setCustomKey(String key, Object value);
}

/// Privacy-preserving telemetry facade for product analytics and crash reports.
class TelemetryService {
  /// Creates a telemetry service.
  TelemetryService({
    required TelemetryServiceStatus status,
    required bool collectionEnabled,
    required DiagnosticsLogger diagnosticsLogger,
    TelemetryAnalyticsClient? analyticsClient,
    TelemetryCrashReporter? crashReporter,
  }) : _status = status,
       _collectionEnabled = collectionEnabled,
       _diagnosticsLogger = diagnosticsLogger,
       _analyticsClient = analyticsClient,
       _crashReporter = crashReporter;

  static final RegExp _safeNamePattern = RegExp('[^a-z0-9_]+');
  static const int _maxFirebaseNameLength = 40;
  static const int _maxFirebaseStringLength = 80;

  final TelemetryServiceStatus _status;
  final DiagnosticsLogger _diagnosticsLogger;
  final TelemetryAnalyticsClient? _analyticsClient;
  final TelemetryCrashReporter? _crashReporter;
  bool _collectionEnabled;

  /// Whether Firebase telemetry is available in this app run.
  bool get isAvailable => _status == TelemetryServiceStatus.ready;

  /// Whether the user has opted in to telemetry collection.
  bool get collectionEnabled => _collectionEnabled;

  /// Availability status for Settings UI and diagnostics.
  TelemetryServiceStatus get status => _status;

  /// Enables or disables analytics and crash reporting collection.
  Future<void> setCollectionEnabled({required bool enabled}) async {
    _collectionEnabled = enabled;
    if (!isAvailable) {
      _diagnosticsLogger.info(
        'telemetry',
        'collection_preference_stored',
        fields: {'enabled': enabled, 'status': _status},
      );
      return;
    }

    final analyticsClient = _analyticsClient;
    final crashReporter = _crashReporter;
    if (analyticsClient == null || crashReporter == null) {
      _diagnosticsLogger.warning(
        'telemetry',
        'client_missing',
        fields: {'enabled': enabled},
      );
      return;
    }

    await analyticsClient.setCollectionEnabled(enabled: enabled);
    await crashReporter.setCollectionEnabled(enabled: enabled);
    if (!enabled) {
      await analyticsClient.resetAnalyticsData();
      await crashReporter.deleteUnsentReports();
    } else {
      await _setCrashMetadata(this);
    }
  }

  /// Records a high-level app startup event.
  Future<void> logAppStarted({required AppMetadata appMetadata}) =>
      _logEvent('app_started', <String, Object?>{
        'platform': defaultTargetPlatform.name,
        'flutter_mode': _flutterMode(),
        'preview_build': appMetadata.isPreviewBuild,
        'diagnostics_enabled': isDiagnosticsLoggingEnabled,
      });

  /// Records a high-level feature-opened event.
  Future<void> logFeatureOpened({required String feature}) =>
      _logEvent('feature_opened', <String, Object?>{'feature': feature});

  /// Records a sanitized Flutter framework error as non-fatal.
  Future<void> recordFlutterError(FlutterErrorDetails details) async {
    if (!_canRecordCrash()) {
      return;
    }
    final crashReporter = _crashReporter;
    if (crashReporter == null) {
      return;
    }
    await crashReporter.recordFlutterError(
      FlutterErrorDetails(
        exception: SanitizedTelemetryError.from(details.exception),
        stack: details.stack,
        library: 'flutter',
        context: ErrorDescription('flutter_error'),
      ),
    );
  }

  /// Records a sanitized Dart error.
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required bool fatal,
  }) async {
    if (!_canRecordCrash()) {
      return;
    }
    final crashReporter = _crashReporter;
    if (crashReporter == null) {
      return;
    }
    await crashReporter.recordError(
      SanitizedTelemetryError.from(error),
      stackTrace,
      fatal: fatal,
    );
  }

  Future<void> _logEvent(String name, Map<String, Object?> parameters) async {
    if (!isAvailable || !_collectionEnabled) {
      return;
    }
    final analyticsClient = _analyticsClient;
    if (analyticsClient == null) {
      return;
    }
    await analyticsClient.logEvent(
      name: _sanitizeFirebaseName(name),
      parameters: _sanitizeParameters(parameters),
    );
  }

  bool _canRecordCrash() => isAvailable && _collectionEnabled;

  Map<String, Object> _sanitizeParameters(Map<String, Object?> parameters) {
    final sanitized = <String, Object>{};
    for (final entry in parameters.entries) {
      final value = _sanitizeParameterValue(entry.value);
      if (value == null) {
        continue;
      }
      sanitized[_sanitizeFirebaseName(entry.key)] = value;
    }
    return sanitized;
  }

  Object? _sanitizeParameterValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is bool) {
      return value ? 1 : 0;
    }
    if (value is num) {
      return value;
    }
    if (value is Enum) {
      return _sanitizeFirebaseString(value.name);
    }
    return _sanitizeFirebaseString(value.toString());
  }

  String _sanitizeFirebaseName(String value) {
    final sanitized = value
        .toLowerCase()
        .replaceAll(_safeNamePattern, '_')
        .replaceAll(RegExp('_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (sanitized.isEmpty) {
      return 'unknown';
    }
    if (sanitized.length <= _maxFirebaseNameLength) {
      return sanitized;
    }
    return sanitized.substring(0, _maxFirebaseNameLength);
  }

  String _sanitizeFirebaseString(String value) {
    final sanitized = _sanitizeFirebaseName(value);
    if (sanitized.length <= _maxFirebaseStringLength) {
      return sanitized;
    }
    return sanitized.substring(0, _maxFirebaseStringLength);
  }

  String _flutterMode() {
    if (kReleaseMode) {
      return 'release';
    }
    if (kProfileMode) {
      return 'profile';
    }
    return 'debug';
  }
}

/// Sanitized error marker that avoids sending exception messages to Crashlytics.
@immutable
class SanitizedTelemetryError implements Exception {
  /// Creates a sanitized telemetry error from a normalized error type.
  const SanitizedTelemetryError(this.errorType);

  /// Creates a sanitized telemetry error from an arbitrary object.
  factory SanitizedTelemetryError.from(Object error) =>
      SanitizedTelemetryError(_sanitizeErrorType(error));

  /// Normalized exception type.
  final String errorType;

  @override
  String toString() => errorType;
}

/// Initializes Firebase telemetry when this build and platform support it.
Future<TelemetryService> createTelemetryService({
  required SettingsService settingsService,
  DiagnosticsLogger? diagnosticsLogger,
  bool firebaseTelemetryEnabled = isFirebaseTelemetryBuildEnabled,
  bool isWeb = kIsWeb,
  TargetPlatform? targetPlatform,
}) async {
  final logger = diagnosticsLogger ?? DiagnosticsLogService.instance;
  final collectionEnabled = await settingsService.getBool(
    SettingKeys.telemetryCollection,
  );
  if (!firebaseTelemetryEnabled) {
    return TelemetryService(
      status: TelemetryServiceStatus.disabledByBuild,
      collectionEnabled: collectionEnabled,
      diagnosticsLogger: logger,
    );
  }
  if (!isFirebaseTelemetrySupportedPlatform(
    isWeb: isWeb,
    targetPlatform: targetPlatform,
  )) {
    return TelemetryService(
      status: TelemetryServiceStatus.unsupportedPlatform,
      collectionEnabled: collectionEnabled,
      diagnosticsLogger: logger,
    );
  }

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    final service = TelemetryService(
      status: TelemetryServiceStatus.ready,
      collectionEnabled: collectionEnabled,
      diagnosticsLogger: logger,
      analyticsClient: _FirebaseTelemetryAnalyticsClient(
        FirebaseAnalytics.instance,
      ),
      crashReporter: _FirebaseTelemetryCrashReporter(
        FirebaseCrashlytics.instance,
      ),
    );
    await service.setCollectionEnabled(enabled: collectionEnabled);
    await _setCrashMetadata(service);
    return service;
  } on FirebaseException catch (error) {
    logger.warning(
      'telemetry',
      'firebase_initialization_failed',
      fields: {'errorType': error.runtimeType, 'code': error.code},
    );
    return TelemetryService(
      status: TelemetryServiceStatus.initializationFailed,
      collectionEnabled: collectionEnabled,
      diagnosticsLogger: logger,
    );
  } on PlatformException catch (error) {
    logger.warning(
      'telemetry',
      'firebase_initialization_failed',
      fields: {'errorType': error.runtimeType, 'code': error.code},
    );
    return TelemetryService(
      status: TelemetryServiceStatus.initializationFailed,
      collectionEnabled: collectionEnabled,
      diagnosticsLogger: logger,
    );
  }
}

/// Whether Firebase telemetry is supported for [targetPlatform].
bool isFirebaseTelemetrySupportedPlatform({
  required bool isWeb,
  TargetPlatform? targetPlatform,
}) {
  if (isWeb) {
    return false;
  }
  return switch (targetPlatform ?? defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => false,
  };
}

/// Provider for the app telemetry service.
final telemetryServiceProvider = Provider<TelemetryService>(
  (ref) => TelemetryService(
    status: TelemetryServiceStatus.disabledByBuild,
    collectionEnabled: false,
    diagnosticsLogger: ref.watch(diagnosticsLoggerProvider),
  ),
);

/// Notifier for the user telemetry collection preference.
class TelemetryCollectionNotifier extends Notifier<bool> {
  late SettingsService _settingsService;
  late TelemetryService _telemetryService;
  bool _disposed = false;

  @override
  bool build() {
    _settingsService = ref.watch(settingsServiceProvider);
    _telemetryService = ref.watch(telemetryServiceProvider);
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    Future.microtask(_init);
    return _telemetryService.collectionEnabled;
  }

  /// Enables or disables telemetry collection.
  Future<void> setEnabled({required bool enabled}) async {
    await _settingsService.setBool(
      SettingKeys.telemetryCollection,
      value: enabled,
    );
    if (enabled) {
      await _settingsService.setString(
        SettingKeys.telemetryOptInPromptState,
        TelemetryOptInPromptChoice.accepted.name,
      );
    }
    await _telemetryService.setCollectionEnabled(enabled: enabled);
    state = enabled;
  }

  Future<void> _init() async {
    final enabled = await _settingsService.getBool(
      SettingKeys.telemetryCollection,
    );
    if (_disposed) {
      return;
    }
    await _telemetryService.setCollectionEnabled(enabled: enabled);
    if (_disposed) {
      return;
    }
    state = enabled;
  }
}

/// Provider for the telemetry collection preference with write capability.
final telemetryCollectionNotifierProvider =
    NotifierProvider<TelemetryCollectionNotifier, bool>(
      TelemetryCollectionNotifier.new,
    );

/// User choice for the one-time telemetry opt-in prompt.
enum TelemetryOptInPromptChoice {
  /// The prompt has not been shown or answered.
  notShown,

  /// The user dismissed the prompt.
  dismissed,

  /// The user accepted telemetry collection.
  accepted,
}

/// Persistent state for the telemetry opt-in prompt.
@immutable
class TelemetryOptInPromptState {
  /// Creates telemetry prompt state.
  const TelemetryOptInPromptState({
    required this.choice,
    required this.appLaunchCount,
  });

  /// User's prompt choice.
  final TelemetryOptInPromptChoice choice;

  /// Number of recorded app launches.
  final int appLaunchCount;

  /// Whether the user has made a final prompt choice.
  bool get isResolved => choice != TelemetryOptInPromptChoice.notShown;

  /// Creates a copy with updated fields.
  TelemetryOptInPromptState copyWith({
    TelemetryOptInPromptChoice? choice,
    int? appLaunchCount,
  }) => TelemetryOptInPromptState(
    choice: choice ?? this.choice,
    appLaunchCount: appLaunchCount ?? this.appLaunchCount,
  );
}

/// Notifier for delayed telemetry prompt state.
class TelemetryOptInPromptNotifier extends Notifier<TelemetryOptInPromptState> {
  /// Minimum number of launches before showing the prompt without a connection.
  static const int minimumLaunchCountForPrompt = 3;

  late SettingsService _settingsService;
  bool _disposed = false;

  @override
  TelemetryOptInPromptState build() {
    _settingsService = ref.watch(settingsServiceProvider);
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    Future.microtask(_init);
    return const TelemetryOptInPromptState(
      choice: TelemetryOptInPromptChoice.notShown,
      appLaunchCount: 0,
    );
  }

  /// Records one app launch for prompt eligibility.
  Future<void> recordAppLaunch() async {
    final loadedState = await _loadState();
    if (loadedState.isResolved) {
      if (!_disposed) {
        state = loadedState;
      }
      return;
    }
    final nextLaunchCount = loadedState.appLaunchCount + 1;
    await _settingsService.setInt(
      SettingKeys.telemetryAppLaunchCount,
      nextLaunchCount,
    );
    if (_disposed) {
      return;
    }
    state = loadedState.copyWith(appLaunchCount: nextLaunchCount);
  }

  /// Accepts the prompt and enables telemetry collection.
  Future<void> accept() async {
    await ref
        .read(telemetryCollectionNotifierProvider.notifier)
        .setEnabled(enabled: true);
    await _settingsService.setString(
      SettingKeys.telemetryOptInPromptState,
      TelemetryOptInPromptChoice.accepted.name,
    );
    if (_disposed) {
      return;
    }
    state = state.copyWith(choice: TelemetryOptInPromptChoice.accepted);
  }

  /// Dismisses the prompt without enabling telemetry collection.
  Future<void> dismiss() async {
    await _settingsService.setString(
      SettingKeys.telemetryOptInPromptState,
      TelemetryOptInPromptChoice.dismissed.name,
    );
    if (_disposed) {
      return;
    }
    state = state.copyWith(choice: TelemetryOptInPromptChoice.dismissed);
  }

  Future<void> _init() async {
    final loadedState = await _loadState();
    if (_disposed) {
      return;
    }
    state = _mergeLoadedState(loadedState);
  }

  Future<TelemetryOptInPromptState> _loadState() async {
    final launchCount =
        await _settingsService.getInt(SettingKeys.telemetryAppLaunchCount) ?? 0;
    final collectionEnabled = await _settingsService.getBool(
      SettingKeys.telemetryCollection,
    );
    if (collectionEnabled) {
      return TelemetryOptInPromptState(
        choice: TelemetryOptInPromptChoice.accepted,
        appLaunchCount: launchCount,
      );
    }
    final choiceName = await _settingsService.getString(
      SettingKeys.telemetryOptInPromptState,
    );
    return TelemetryOptInPromptState(
      choice: _parsePromptChoice(choiceName),
      appLaunchCount: launchCount,
    );
  }

  TelemetryOptInPromptChoice _parsePromptChoice(String? value) =>
      switch (value) {
        'dismissed' => TelemetryOptInPromptChoice.dismissed,
        'accepted' => TelemetryOptInPromptChoice.accepted,
        _ => TelemetryOptInPromptChoice.notShown,
      };

  TelemetryOptInPromptState _mergeLoadedState(
    TelemetryOptInPromptState loadedState,
  ) {
    final currentState = state;
    return TelemetryOptInPromptState(
      choice: currentState.isResolved
          ? currentState.choice
          : loadedState.choice,
      appLaunchCount: currentState.appLaunchCount > loadedState.appLaunchCount
          ? currentState.appLaunchCount
          : loadedState.appLaunchCount,
    );
  }
}

/// Provider for telemetry prompt state.
final telemetryOptInPromptNotifierProvider =
    NotifierProvider<TelemetryOptInPromptNotifier, TelemetryOptInPromptState>(
      TelemetryOptInPromptNotifier.new,
    );

class _FirebaseTelemetryAnalyticsClient implements TelemetryAnalyticsClient {
  const _FirebaseTelemetryAnalyticsClient(this._analytics);

  final FirebaseAnalytics _analytics;

  @override
  Future<void> logEvent({
    required String name,
    required Map<String, Object> parameters,
  }) => _analytics.logEvent(name: name, parameters: parameters);

  @override
  Future<void> resetAnalyticsData() => _analytics.resetAnalyticsData();

  @override
  Future<void> setCollectionEnabled({required bool enabled}) =>
      _analytics.setAnalyticsCollectionEnabled(enabled);
}

class _FirebaseTelemetryCrashReporter implements TelemetryCrashReporter {
  const _FirebaseTelemetryCrashReporter(this._crashlytics);

  final FirebaseCrashlytics _crashlytics;

  @override
  Future<void> deleteUnsentReports() => _crashlytics.deleteUnsentReports();

  @override
  Future<void> recordError(
    Object error,
    StackTrace stackTrace, {
    required bool fatal,
  }) => _crashlytics.recordError(error, stackTrace, fatal: fatal);

  @override
  Future<void> recordFlutterError(FlutterErrorDetails details) =>
      _crashlytics.recordFlutterError(details);

  @override
  Future<void> setCollectionEnabled({required bool enabled}) =>
      _crashlytics.setCrashlyticsCollectionEnabled(enabled);

  @override
  Future<void> setCustomKey(String key, Object value) =>
      _crashlytics.setCustomKey(key, value);
}

Future<void> _setCrashMetadata(TelemetryService service) async {
  if (!service.isAvailable || !service.collectionEnabled) {
    return;
  }
  final crashReporter = service._crashReporter;
  if (crashReporter == null) {
    return;
  }
  await crashReporter.setCustomKey('platform', defaultTargetPlatform.name);
  await crashReporter.setCustomKey('flutter_mode', service._flutterMode());
  await crashReporter.setCustomKey(
    'diagnostics_enabled',
    isDiagnosticsLoggingEnabled,
  );
}

String _sanitizeErrorType(Object error) {
  final errorType = switch (error) {
    FirebaseException() => 'FirebaseException',
    PlatformException() => 'PlatformException',
    TimeoutException() => 'TimeoutException',
    FormatException() => 'FormatException',
    ArgumentError() => 'ArgumentError',
    AssertionError() => 'AssertionError',
    StateError() => 'StateError',
    TypeError() => 'TypeError',
    UnimplementedError() => 'UnimplementedError',
    UnsupportedError() => 'UnsupportedError',
    Error() => 'Error',
    Exception() => 'Exception',
    _ => 'Object',
  };
  final sanitized = errorType
      .replaceAll(RegExp('[^A-Za-z0-9_.-]+'), '_')
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (sanitized.isEmpty) {
    return 'UnknownError';
  }
  return sanitized.length <= 80 ? sanitized : sanitized.substring(0, 80);
}
