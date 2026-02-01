import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';

/// Keys for app settings.
abstract final class SettingKeys {
  /// Theme mode: 'system', 'light', 'dark'.
  static const themeMode = 'theme_mode';

  /// Terminal font family.
  static const terminalFont = 'terminal_font';

  /// Terminal font size.
  static const terminalFontSize = 'terminal_font_size';

  /// Terminal color scheme name.
  static const terminalColorScheme = 'terminal_color_scheme';

  /// Default terminal theme ID for light mode.
  static const defaultTerminalThemeLight = 'default_terminal_theme_light';

  /// Default terminal theme ID for dark mode.
  static const defaultTerminalThemeDark = 'default_terminal_theme_dark';

  /// Custom terminal themes (JSON array).
  static const customTerminalThemes = 'custom_terminal_themes';

  /// Terminal cursor style.
  static const cursorStyle = 'cursor_style';

  /// Terminal bell sound enabled.
  static const bellSound = 'bell_sound';

  /// Enable haptic feedback.
  static const hapticFeedback = 'haptic_feedback';

  /// Keyboard toolbar configuration.
  static const keyboardToolbar = 'keyboard_toolbar';

  /// Auto-reconnect on connection drop.
  static const autoReconnect = 'auto_reconnect';

  /// Keep-alive interval in seconds.
  static const keepAliveInterval = 'keep_alive_interval';

  /// Default SSH port.
  static const defaultPort = 'default_port';

  /// Default username.
  static const defaultUsername = 'default_username';

  /// Auto-lock timeout in minutes.
  static const autoLockTimeout = 'auto_lock_timeout';
}

/// Service for managing app settings.
class SettingsService {
  /// Creates a new [SettingsService].
  SettingsService(this._db);

  final AppDatabase _db;

  /// Get a string setting.
  Future<String?> getString(String key) async {
    final result = await (_db.select(
      _db.settings,
    )..where((s) => s.key.equals(key))).getSingleOrNull();
    return result?.value;
  }

  /// Get an int setting.
  Future<int?> getInt(String key) async {
    final value = await getString(key);
    return value != null ? int.tryParse(value) : null;
  }

  /// Get a bool setting.
  Future<bool> getBool(String key, {bool defaultValue = false}) async {
    final value = await getString(key);
    if (value == 'true') return true;
    if (value == 'false') return false;
    return defaultValue;
  }

  /// Get a JSON setting.
  Future<Map<String, dynamic>?> getJson(String key) async {
    final value = await getString(key);
    if (value == null) return null;
    try {
      return jsonDecode(value) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
  }

  /// Set a string setting.
  Future<void> setString(String key, String value) async {
    await _db
        .into(_db.settings)
        .insertOnConflictUpdate(
          SettingsCompanion.insert(key: key, value: value),
        );
  }

  /// Set an int setting.
  Future<void> setInt(String key, int value) =>
      setString(key, value.toString());

  /// Set a bool setting.
  Future<void> setBool(String key, {required bool value}) =>
      setString(key, value.toString());

  /// Set a JSON setting.
  Future<void> setJson(String key, Map<String, dynamic> value) =>
      setString(key, jsonEncode(value));

  /// Delete a setting.
  Future<void> delete(String key) async {
    await (_db.delete(_db.settings)..where((s) => s.key.equals(key))).go();
  }

  /// Get all settings.
  Future<Map<String, String>> getAll() async {
    final results = await _db.select(_db.settings).get();
    return Map.fromEntries(results.map((s) => MapEntry(s.key, s.value)));
  }

  /// Watch a setting.
  Stream<String?> watchString(String key) => (_db.select(
    _db.settings,
  )..where((s) => s.key.equals(key))).watchSingleOrNull().map((s) => s?.value);
}

/// Provider for [SettingsService].
final settingsServiceProvider = Provider<SettingsService>(
  (ref) => SettingsService(ref.watch(databaseProvider)),
);

/// Provider for theme mode setting.
final themeModeProvider = FutureProvider<String>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  return await settings.getString(SettingKeys.themeMode) ?? 'system';
});

/// Notifier for theme mode with write capability.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  late final SettingsService _settings;
  bool _disposed = false;

  @override
  ThemeMode build() {
    _settings = ref.watch(settingsServiceProvider);
    ref.onDispose(() => _disposed = true);
    _init();
    return ThemeMode.system;
  }

  Future<void> _init() async {
    final value = await _settings.getString(SettingKeys.themeMode) ?? 'system';
    if (_disposed) return;
    state = _parseThemeMode(value);
  }

  /// Set the theme mode.
  Future<void> setThemeMode(ThemeMode mode) async {
    final value = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await _settings.setString(SettingKeys.themeMode, value);
    state = mode;
  }

  ThemeMode _parseThemeMode(String value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

/// Provider for theme mode with write capability.
final themeModeNotifierProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

/// Provider for font size setting.
final fontSizeProvider = FutureProvider<double>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  final value = await settings.getInt(SettingKeys.terminalFontSize);
  return value?.toDouble() ?? 14.0;
});

/// Notifier for font size with write capability.
class FontSizeNotifier extends Notifier<double> {
  late final SettingsService _settings;
  bool _disposed = false;

  @override
  double build() {
    _settings = ref.watch(settingsServiceProvider);
    ref.onDispose(() => _disposed = true);
    _init();
    return 14;
  }

  Future<void> _init() async {
    final value = await _settings.getInt(SettingKeys.terminalFontSize);
    if (_disposed) return;
    state = value?.toDouble() ?? 14.0;
  }

  /// Set the font size.
  Future<void> setFontSize(double size) async {
    await _settings.setInt(SettingKeys.terminalFontSize, size.round());
    state = size;
  }
}

/// Provider for font size with write capability.
final fontSizeNotifierProvider = NotifierProvider<FontSizeNotifier, double>(
  FontSizeNotifier.new,
);

/// Provider for font family setting.
final fontFamilyProvider = FutureProvider<String>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  return await settings.getString(SettingKeys.terminalFont) ?? 'monospace';
});

/// Notifier for font family with write capability.
class FontFamilyNotifier extends Notifier<String> {
  late final SettingsService _settings;
  bool _disposed = false;

  @override
  String build() {
    _settings = ref.watch(settingsServiceProvider);
    ref.onDispose(() => _disposed = true);
    _init();
    return 'monospace';
  }

  Future<void> _init() async {
    final value = await _settings.getString(SettingKeys.terminalFont);
    if (_disposed) return;
    state = value ?? 'monospace';
  }

  /// Set the font family.
  Future<void> setFontFamily(String family) async {
    await _settings.setString(SettingKeys.terminalFont, family);
    state = family;
  }
}

/// Provider for font family with write capability.
final fontFamilyNotifierProvider = NotifierProvider<FontFamilyNotifier, String>(
  FontFamilyNotifier.new,
);

/// Provider for auto-lock timeout setting.
final autoLockTimeoutProvider = FutureProvider<int>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  return await settings.getInt(SettingKeys.autoLockTimeout) ?? 5;
});

/// Notifier for auto-lock timeout with write capability.
class AutoLockTimeoutNotifier extends Notifier<int> {
  late final SettingsService _settings;
  bool _disposed = false;

  @override
  int build() {
    _settings = ref.watch(settingsServiceProvider);
    ref.onDispose(() => _disposed = true);
    _init();
    return 5;
  }

  Future<void> _init() async {
    final value = await _settings.getInt(SettingKeys.autoLockTimeout);
    if (_disposed) return;
    state = value ?? 5;
  }

  /// Set the auto-lock timeout in minutes.
  Future<void> setTimeout(int minutes) async {
    await _settings.setInt(SettingKeys.autoLockTimeout, minutes);
    state = minutes;
  }
}

/// Provider for auto-lock timeout with write capability.
final autoLockTimeoutNotifierProvider =
    NotifierProvider<AutoLockTimeoutNotifier, int>(AutoLockTimeoutNotifier.new);

/// Provider for haptic feedback setting.
final hapticFeedbackProvider = FutureProvider<bool>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  return settings.getBool(SettingKeys.hapticFeedback, defaultValue: true);
});

/// Notifier for haptic feedback with write capability.
class HapticFeedbackNotifier extends Notifier<bool> {
  late final SettingsService _settings;
  bool _disposed = false;

  @override
  bool build() {
    _settings = ref.watch(settingsServiceProvider);
    ref.onDispose(() => _disposed = true);
    _init();
    return true;
  }

  Future<void> _init() async {
    final value = await _settings.getBool(
      SettingKeys.hapticFeedback,
      defaultValue: true,
    );
    if (_disposed) return;
    state = value;
  }

  /// Set haptic feedback enabled.
  Future<void> setEnabled({required bool enabled}) async {
    await _settings.setBool(SettingKeys.hapticFeedback, value: enabled);
    state = enabled;
  }
}

/// Provider for haptic feedback with write capability.
final hapticFeedbackNotifierProvider =
    NotifierProvider<HapticFeedbackNotifier, bool>(HapticFeedbackNotifier.new);

/// Provider for cursor style setting.
final cursorStyleProvider = FutureProvider<String>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  return await settings.getString(SettingKeys.cursorStyle) ?? 'block';
});

/// Notifier for cursor style with write capability.
class CursorStyleNotifier extends Notifier<String> {
  late final SettingsService _settings;
  bool _disposed = false;

  @override
  String build() {
    _settings = ref.watch(settingsServiceProvider);
    ref.onDispose(() => _disposed = true);
    _init();
    return 'block';
  }

  Future<void> _init() async {
    final value = await _settings.getString(SettingKeys.cursorStyle);
    if (_disposed) return;
    state = value ?? 'block';
  }

  /// Set the cursor style.
  Future<void> setCursorStyle(String style) async {
    await _settings.setString(SettingKeys.cursorStyle, style);
    state = style;
  }
}

/// Provider for cursor style with write capability.
final cursorStyleNotifierProvider =
    NotifierProvider<CursorStyleNotifier, String>(CursorStyleNotifier.new);

/// Provider for bell sound setting.
final bellSoundProvider = FutureProvider<bool>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  return settings.getBool(SettingKeys.bellSound, defaultValue: true);
});

/// Notifier for bell sound with write capability.
class BellSoundNotifier extends Notifier<bool> {
  late final SettingsService _settings;
  bool _disposed = false;

  @override
  bool build() {
    _settings = ref.watch(settingsServiceProvider);
    ref.onDispose(() => _disposed = true);
    _init();
    return true;
  }

  Future<void> _init() async {
    final value = await _settings.getBool(
      SettingKeys.bellSound,
      defaultValue: true,
    );
    if (_disposed) return;
    state = value;
  }

  /// Set bell sound enabled.
  Future<void> setEnabled({required bool enabled}) async {
    await _settings.setBool(SettingKeys.bellSound, value: enabled);
    state = enabled;
  }
}

/// Provider for bell sound with write capability.
final bellSoundNotifierProvider = NotifierProvider<BellSoundNotifier, bool>(
  BellSoundNotifier.new,
);

/// State for terminal theme settings (light and dark).
class TerminalThemeSettings {
  /// Creates a new [TerminalThemeSettings].
  const TerminalThemeSettings({
    required this.lightThemeId,
    required this.darkThemeId,
  });

  /// Theme ID for light mode.
  final String lightThemeId;

  /// Theme ID for dark mode.
  final String darkThemeId;

  /// Creates a copy with the given fields replaced.
  TerminalThemeSettings copyWith({String? lightThemeId, String? darkThemeId}) =>
      TerminalThemeSettings(
        lightThemeId: lightThemeId ?? this.lightThemeId,
        darkThemeId: darkThemeId ?? this.darkThemeId,
      );
}

/// Notifier for terminal theme settings.
class TerminalThemeSettingsNotifier extends Notifier<TerminalThemeSettings> {
  late final SettingsService _settings;
  bool _disposed = false;

  @override
  TerminalThemeSettings build() {
    _settings = ref.watch(settingsServiceProvider);
    ref.onDispose(() => _disposed = true);
    _init();
    return const TerminalThemeSettings(
      lightThemeId: 'github-light',
      darkThemeId: 'dracula',
    );
  }

  Future<void> _init() async {
    final light = await _settings.getString(
      SettingKeys.defaultTerminalThemeLight,
    );
    final dark = await _settings.getString(
      SettingKeys.defaultTerminalThemeDark,
    );
    if (_disposed) return;
    state = TerminalThemeSettings(
      lightThemeId: light ?? 'github-light',
      darkThemeId: dark ?? 'dracula',
    );
  }

  /// Set the light mode theme.
  Future<void> setLightTheme(String themeId) async {
    await _settings.setString(SettingKeys.defaultTerminalThemeLight, themeId);
    state = state.copyWith(lightThemeId: themeId);
  }

  /// Set the dark mode theme.
  Future<void> setDarkTheme(String themeId) async {
    await _settings.setString(SettingKeys.defaultTerminalThemeDark, themeId);
    state = state.copyWith(darkThemeId: themeId);
  }
}

/// Provider for terminal theme settings.
final terminalThemeSettingsProvider =
    NotifierProvider<TerminalThemeSettingsNotifier, TerminalThemeSettings>(
      TerminalThemeSettingsNotifier.new,
    );
