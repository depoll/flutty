import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/host_key_prompt.dart';
import 'data/database/database.dart';
import 'domain/services/host_key_prompt_handler_provider.dart';
import 'domain/services/settings_service.dart';
import 'domain/services/telemetry_service.dart';

/// Entry point for the MonkeySSH client.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = AppDatabase();
  final settingsService = SettingsService(database);
  final telemetryService = await createTelemetryService(
    settingsService: settingsService,
  );
  installTelemetryErrorHandlers(telemetryService);
  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        settingsServiceProvider.overrideWithValue(settingsService),
        telemetryServiceProvider.overrideWithValue(telemetryService),
        hostKeyPromptHandlerProvider.overrideWith(
          (ref) => createHostKeyPromptHandler(),
        ),
      ],
      child: const FluttyApp(),
    ),
  );
}

/// Installs global Flutter/Dart error hooks for sanitized telemetry reporting.
@visibleForTesting
void installTelemetryErrorHandlers(TelemetryService telemetryService) {
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
    unawaited(
      telemetryService
          .recordError(error, stackTrace, fatal: false)
          .catchError((Object _) {}),
    );
    return previousPlatformErrorHandler?.call(error, stackTrace) ?? true;
  };
}
