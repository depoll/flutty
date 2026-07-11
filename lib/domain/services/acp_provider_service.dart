import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_provider.dart';
import 'settings_service.dart';

/// Persists and lists ACP provider definitions.
///
/// This service only manages provider *configuration* (built-in presets plus
/// user-approved custom launch commands). It never reads, logs, or persists
/// ACP session transcripts, prompts, or command output.
class AcpProviderService {
  /// Creates a new [AcpProviderService].
  AcpProviderService(this._settings);

  final SettingsService _settings;

  /// All built-in ACP providers bundled with the app.
  List<AcpBuiltinProvider> get builtinProviders => acpBuiltinProviders;

  /// Loads all persisted custom provider definitions, in stored order.
  ///
  /// Malformed storage (invalid JSON, an unexpected shape, or entries that
  /// fail validation) is handled defensively: unreadable entries are skipped
  /// rather than surfaced as an error, so a single corrupt entry never
  /// prevents the rest of the list from loading.
  Future<List<AcpCustomProviderDefinition>> listCustomProviders() async {
    final raw = await _settings.getString(SettingKeys.acpCustomProviders);
    if (raw == null || raw.isEmpty) {
      return const [];
    }

    List<dynamic> decoded;
    try {
      final value = jsonDecode(raw);
      if (value is! List) {
        return const [];
      }
      decoded = value;
    } on FormatException {
      return const [];
    }

    final definitions = <AcpCustomProviderDefinition>[];
    for (final item in decoded) {
      final definition = AcpCustomProviderDefinition.tryFromJson(item);
      if (definition != null) {
        definitions.add(definition);
      }
    }
    return List.unmodifiable(definitions);
  }

  /// Loads a single persisted custom provider by [id], if one exists.
  Future<AcpCustomProviderDefinition?> getCustomProvider(String id) async {
    final providers = await listCustomProviders();
    return providers.firstWhereOrNull((provider) => provider.id == id);
  }

  /// Lists built-in providers followed by persisted custom providers.
  Future<List<AcpProvider>> listAllProviders() async {
    final custom = await listCustomProviders();
    return [
      for (final builtin in builtinProviders) AcpBuiltinProviderView(builtin),
      for (final definition in custom) AcpCustomProviderView(definition),
    ];
  }

  /// Saves [definition], inserting it or updating an existing entry with the
  /// same ID in place without disturbing the order of other entries.
  Future<void> saveCustomProvider(
    AcpCustomProviderDefinition definition,
  ) async {
    final providers = await listCustomProviders();
    final index = providers.indexWhere(
      (provider) => provider.id == definition.id,
    );
    final updated = List<AcpCustomProviderDefinition>.from(providers);
    if (index >= 0) {
      updated[index] = definition;
    } else {
      updated.add(definition);
    }
    await _writeCustomProviders(updated);
  }

  /// Removes the persisted custom provider with [id], if one exists.
  Future<void> removeCustomProvider(String id) async {
    final providers = await listCustomProviders();
    final updated = providers
        .where((provider) => provider.id != id)
        .toList(growable: false);
    if (updated.length == providers.length) {
      return;
    }
    await _writeCustomProviders(updated);
  }

  Future<void> _writeCustomProviders(
    List<AcpCustomProviderDefinition> providers,
  ) async {
    if (providers.isEmpty) {
      await _settings.delete(SettingKeys.acpCustomProviders);
      return;
    }
    final encoded = jsonEncode([
      for (final provider in providers) provider.toJson(),
    ]);
    await _settings.setString(SettingKeys.acpCustomProviders, encoded);
  }
}

/// Provider for [AcpProviderService].
final acpProviderServiceProvider = Provider<AcpProviderService>(
  (ref) => AcpProviderService(ref.watch(settingsServiceProvider)),
);

/// Provider for the combined list of built-in and persisted custom ACP
/// providers.
final acpProvidersProvider = FutureProvider<List<AcpProvider>>(
  (ref) => ref.watch(acpProviderServiceProvider).listAllProviders(),
);
