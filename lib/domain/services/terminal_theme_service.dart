import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../models/terminal_theme.dart';
import '../models/terminal_themes.dart';
import 'settings_service.dart';

/// Service for managing terminal themes.
///
/// Provides methods for resolving the appropriate theme for a host,
/// listing all available themes, and managing custom themes.
class TerminalThemeService {
  /// Creates a new [TerminalThemeService].
  TerminalThemeService(this._settings);

  final SettingsService _settings;

  /// Gets the theme for a host based on current brightness.
  ///
  /// Resolution order:
  /// 1. Host-specific override for the current brightness
  /// 2. Global default for the current brightness
  /// 3. Built-in default theme
  Future<TerminalThemeData> getThemeForHost(
    Host? host,
    Brightness brightness,
  ) async {
    final isDark = brightness == Brightness.dark;

    // 1. Check host-specific override
    if (host != null) {
      final hostThemeId = isDark
          ? host.terminalThemeDarkId
          : host.terminalThemeLightId;
      if (hostThemeId != null) {
        final theme = await getThemeById(hostThemeId);
        if (theme != null) return theme;
      }
    }

    // 2. Fall back to global default
    final globalThemeId = isDark
        ? await _settings.getString(SettingKeys.defaultTerminalThemeDark)
        : await _settings.getString(SettingKeys.defaultTerminalThemeLight);

    if (globalThemeId != null) {
      final theme = await getThemeById(globalThemeId);
      if (theme != null) return theme;
    }

    // 3. Built-in default
    return isDark ? TerminalThemes.midnightPurple : TerminalThemes.cleanWhite;
  }

  /// Gets a theme by ID (checks built-in themes first, then custom).
  Future<TerminalThemeData?> getThemeById(String id) async {
    // Check built-in themes first
    final builtIn = TerminalThemes.getById(id);
    if (builtIn != null) return builtIn;

    // Check custom themes
    final customThemes = await getCustomThemes();
    for (final theme in customThemes) {
      if (theme.id == id) return theme;
    }
    return null;
  }

  /// Gets all available themes (built-in + custom).
  Future<List<TerminalThemeData>> getAllThemes() async {
    final custom = await getCustomThemes();
    return [...TerminalThemes.all, ...custom];
  }

  /// Gets all dark themes.
  Future<List<TerminalThemeData>> getDarkThemes() async {
    final all = await getAllThemes();
    return all.where((t) => t.isDark).toList();
  }

  /// Gets all light themes.
  Future<List<TerminalThemeData>> getLightThemes() async {
    final all = await getAllThemes();
    return all.where((t) => !t.isDark).toList();
  }

  /// Gets all custom themes.
  Future<List<TerminalThemeData>> getCustomThemes() async {
    final json = await _settings.getString(SettingKeys.customTerminalThemes);
    if (json == null || json.isEmpty) return [];

    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => TerminalThemeData.fromJson(e as Map<String, dynamic>))
          .toList();
    } on FormatException {
      return [];
    }
  }

  /// Saves a custom theme.
  Future<void> saveCustomTheme(TerminalThemeData theme) async {
    final themes = await getCustomThemes();

    // Update existing or add new
    final index = themes.indexWhere((t) => t.id == theme.id);
    if (index >= 0) {
      themes[index] = theme;
    } else {
      themes.add(theme.copyWith(isCustom: true));
    }

    await _saveCustomThemes(themes);
  }

  /// Deletes a custom theme.
  Future<void> deleteCustomTheme(String themeId) async {
    final themes = await getCustomThemes();
    themes.removeWhere((t) => t.id == themeId);
    await _saveCustomThemes(themes);
  }

  Future<void> _saveCustomThemes(List<TerminalThemeData> themes) async {
    final json = jsonEncode(themes.map((t) => t.toJson()).toList());
    await _settings.setString(SettingKeys.customTerminalThemes, json);
  }
}

/// Provider for [TerminalThemeService].
final terminalThemeServiceProvider = Provider<TerminalThemeService>(
  (ref) => TerminalThemeService(ref.watch(settingsServiceProvider)),
);

/// Provider for all available themes.
final allTerminalThemesProvider = FutureProvider<List<TerminalThemeData>>((
  ref,
) {
  final service = ref.watch(terminalThemeServiceProvider);
  return service.getAllThemes();
});

/// Provider for custom themes only.
final customTerminalThemesProvider = FutureProvider<List<TerminalThemeData>>((
  ref,
) {
  final service = ref.watch(terminalThemeServiceProvider);
  return service.getCustomThemes();
});
