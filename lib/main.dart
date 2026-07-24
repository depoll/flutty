import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:xterm/xterm.dart';

import 'app/app.dart';
import 'app/app_metadata.dart';
import 'app/host_key_prompt.dart';
import 'app/interactive_auth_prompt.dart';
import 'data/database/database.dart';
import 'domain/services/diagnostics_log_service.dart';
import 'domain/services/host_key_prompt_handler_provider.dart';
import 'domain/services/interactive_auth_prompt.dart';
import 'domain/services/performance_diagnostics_service.dart';
import 'domain/services/settings_service.dart';
import 'domain/services/ssh_error_policy.dart';
import 'domain/services/telemetry_service.dart';

/// Entry point for the MonkeySSH client.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installPerformanceDiagnostics();
  final database = AppDatabase();
  final settingsService = SettingsService(database);
  final telemetryService = await createTelemetryService(
    settingsService: settingsService,
  );
  _installTelemetryErrorHandlers(telemetryService);
  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        settingsServiceProvider.overrideWithValue(settingsService),
        telemetryServiceProvider.overrideWithValue(telemetryService),
        hostKeyPromptHandlerProvider.overrideWith(
          (ref) => createHostKeyPromptHandler(),
        ),
        interactiveAuthPromptHandlerProvider.overrideWith(
          (ref) => createInteractiveAuthPromptHandler(),
        ),
      ],
      child: const FluttyApp(),
    ),
  );
}

void _installPerformanceDiagnostics() {
  if (!isDiagnosticsLoggingEnabled) {
    return;
  }
  // Frame jank monitor: discriminates UI-thread vs raster-thread stalls.
  PerformanceDiagnosticsService.instance.start();
  // Surface terminal image inflate/decode timing from the vendored xterm.
  terminalGraphicsDecodeObserver =
      ({
        required int payloadBytes,
        required int inflateMicros,
        required int decodeMicros,
        required bool compressed,
        required bool success,
        String? imageId,
        String? action,
        bool? reused,
      }) => logTerminalGraphicsDecode(
        TerminalGraphicsDecodeStats(
          payloadBytes: payloadBytes,
          inflateMicros: inflateMicros,
          decodeMicros: decodeMicros,
          compressed: compressed,
          success: success,
          imageId: imageId,
          action: action,
          reused: reused ?? false,
        ),
      );
}

void _installTelemetryErrorHandlers(TelemetryService telemetryService) {
  final previousFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    if (previousFlutterErrorHandler != null) {
      previousFlutterErrorHandler(details);
    } else {
      FlutterError.presentError(details);
    }
    unawaited(
      telemetryService.recordFlutterError(details).catchError((Object _) {}),
    );
  };

  final previousPlatformErrorHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    if (isExpectedSshChannelTeardownError(error, stackTrace)) {
      DiagnosticsLogService.instance.info(
        'ssh.channel',
        'late_write_ignored',
        fields: {'errorType': error.runtimeType},
      );
      previousPlatformErrorHandler?.call(error, stackTrace);
      return true;
    }
    unawaited(
      telemetryService
          .recordError(error, stackTrace, fatal: true)
          .catchError((Object _) {}),
    );
    return previousPlatformErrorHandler?.call(error, stackTrace) ?? false;
  };
}
