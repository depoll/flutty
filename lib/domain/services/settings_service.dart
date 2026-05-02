import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../models/terminal_theme.dart';
import '../models/terminal_themes.dart';

/// Keys for app settings.
abstract final class SettingKeys {
  /// Theme mode: 'system', 'light', 'dark'.
  static const themeMode = 'theme_mode';

  /// Whether terminal themes also style app chrome.
  static const terminalThemesApplyToApp = 'terminal_themes_apply_to_app';

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

  /// Keep the device awake while a terminal is active.
  static const terminalWakeLock = 'terminal_wake_lock';

  /// Enable tapping terminal file paths to open SFTP.
  static const terminalPathLinks = 'terminal_path_links';

  /// Show underlines for clickable terminal file paths.
  static const terminalPathLinkUnderlines = 'terminal_path_link_badges';

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

  /// Whether MonkeySSH Pro is currently unlocked from the store.
  static const monetizationProUnlocked = 'monetization_pro_unlocked';

  /// Active product ID that most recently unlocked MonkeySSH Pro.
  static const monetizationActiveProductId = 'monetization_active_product_id';

  /// Active offer ID that most recently unlocked MonkeySSH Pro.
  static const monetizationActiveOfferId = 'monetization_active_offer_id';

  /// Timestamp of the most recent entitlement update.
  static const monetizationEntitlementUpdatedAt =
      'monetization_entitlement_updated_at';

  /// Debug-only local premium override.
  static const monetizationDebugUnlocked = 'monetization_debug_unlocked';

  /// Saved host-scoped coding-agent launch presets.
  static const agentLaunchPresets = 'agent_launch_presets';

  /// Saved host IDs pinned into the app's home-screen shortcut set.
  static const homeScreenShortcutHostIds = 'home_screen_shortcut_host_ids';

  /// Saved host-scoped coding CLI launch preferences.
  static const hostCliLaunchPreferences = 'host_cli_launch_preferences';

  /// Enable shared clipboard between device and remote session.
  ///
  /// The remote host can update the local clipboard through OSC 52 and remote
  /// clipboard utilities when available.
  static const sharedClipboard = 'shared_clipboard';

  /// Allow the remote host to read the local clipboard.
  static const sharedClipboardLocalRead = 'shared_clipboard_local_read';

  /// Whether tapping the terminal automatically shows the keyboard.
  ///
  /// When disabled, the keyboard can only be toggled via the toolbar button.
  static const tapToShowKeyboard = 'tap_to_show_keyboard';
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

abstract class _AsyncSettingsNotifier<T> extends Notifier<T> {
  late SettingsService _settings;
  bool _disposed = false;

  SettingsService get _settingsService => _settings;

  bool get _isDisposed => _disposed;

  T get _defaultValue;

  Future<T> _loadValue();

  @override
  T build() {
    _settings = ref.watch(settingsServiceProvider);
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    Future.microtask(_init);
    return _defaultValue;
  }

  Future<void> _init() async {
    if (_disposed) return;
    final value = await _loadValue();
    if (_disposed) return;
    state = value;
  }
}

/// Provider for theme mode setting.
final themeModeProvider = FutureProvider<String>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  return await settings.getString(SettingKeys.themeMode) ?? 'system';
});

/// Notifier for theme mode with write capability.
class ThemeModeNotifier extends _AsyncSettingsNotifier<ThemeMode> {
  @override
  ThemeMode get _defaultValue => ThemeMode.system;

  @override
  Future<ThemeMode> _loadValue() async {
    final value =
        await _settingsService.getString(SettingKeys.themeMode) ?? 'system';
    return _parseThemeMode(value);
  }

  /// Set the theme mode.
  Future<void> setThemeMode(ThemeMode mode) async {
    final value = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await _settingsService.setString(SettingKeys.themeMode, value);
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

/// Provider for terminal themes applying to app chrome.
final terminalThemesApplyToAppProvider = FutureProvider<bool>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  return settings.getBool(
    SettingKeys.terminalThemesApplyToApp,
    defaultValue: true,
  );
});

/// Notifier for terminal themes applying to app chrome.
class TerminalThemesApplyToAppNotifier extends _AsyncSettingsNotifier<bool> {
  @override
  bool get _defaultValue => true;

  @override
  Future<bool> _loadValue() => _settingsService.getBool(
    SettingKeys.terminalThemesApplyToApp,
    defaultValue: true,
  );

  /// Set whether terminal themes also style app chrome.
  Future<void> setEnabled({required bool enabled}) async {
    await _settingsService.setBool(
      SettingKeys.terminalThemesApplyToApp,
      value: enabled,
    );
    state = enabled;
    ref.invalidate(terminalThemesApplyToAppProvider);
  }
}

/// Provider for terminal themes applying to app chrome with write capability.
final terminalThemesApplyToAppNotifierProvider =
    NotifierProvider<TerminalThemesApplyToAppNotifier, bool>(
      TerminalThemesApplyToAppNotifier.new,
    );

/// Provider for font size setting.
final fontSizeProvider = FutureProvider<double>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  final value = await settings.getInt(SettingKeys.terminalFontSize);
  return value?.toDouble() ?? 14.0;
});

/// Notifier for font size with write capability.
class FontSizeNotifier extends _AsyncSettingsNotifier<double> {
  Future<void> _writeChain = Future<void>.value();
  int _latestWriteToken = 0;

  @override
  double get _defaultValue => 14;

  @override
  Future<double> _loadValue() async {
    final value = await _settingsService.getInt(SettingKeys.terminalFontSize);
    return value?.toDouble() ?? 14.0;
  }

  /// Set the font size.
  Future<void> setFontSize(double size) async {
    state = size;
    final writeToken = ++_latestWriteToken;
    final nextWrite = _writeChain.catchError((Object _) {}).then((_) async {
      if (_isDisposed || writeToken != _latestWriteToken) {
        return;
      }
      await _settingsService.setInt(SettingKeys.terminalFontSize, size.round());
    });
    _writeChain = nextWrite;
    await nextWrite;
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
class FontFamilyNotifier extends _AsyncSettingsNotifier<String> {
  @override
  String get _defaultValue => 'monospace';

  @override
  Future<String> _loadValue() async =>
      await _settingsService.getString(SettingKeys.terminalFont) ?? 'monospace';

  /// Set the font family.
  Future<void> setFontFamily(String family) async {
    await _settingsService.setString(SettingKeys.terminalFont, family);
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
class AutoLockTimeoutNotifier extends _AsyncSettingsNotifier<int> {
  @override
  int get _defaultValue => 5;

  @override
  Future<int> _loadValue() async =>
      await _settingsService.getInt(SettingKeys.autoLockTimeout) ?? 5;

  /// Set the auto-lock timeout in minutes.
  Future<void> setTimeout(int minutes) async {
    await _settingsService.setInt(SettingKeys.autoLockTimeout, minutes);
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
class HapticFeedbackNotifier extends _AsyncSettingsNotifier<bool> {
  @override
  bool get _defaultValue => true;

  @override
  Future<bool> _loadValue() =>
      _settingsService.getBool(SettingKeys.hapticFeedback, defaultValue: true);

  /// Set haptic feedback enabled.
  Future<void> setEnabled({required bool enabled}) async {
    await _settingsService.setBool(SettingKeys.hapticFeedback, value: enabled);
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
class CursorStyleNotifier extends _AsyncSettingsNotifier<String> {
  @override
  String get _defaultValue => 'block';

  @override
  Future<String> _loadValue() async =>
      await _settingsService.getString(SettingKeys.cursorStyle) ?? 'block';

  /// Set the cursor style.
  Future<void> setCursorStyle(String style) async {
    await _settingsService.setString(SettingKeys.cursorStyle, style);
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
class BellSoundNotifier extends _AsyncSettingsNotifier<bool> {
  @override
  bool get _defaultValue => true;

  @override
  Future<bool> _loadValue() =>
      _settingsService.getBool(SettingKeys.bellSound, defaultValue: true);

  /// Set bell sound enabled.
  Future<void> setEnabled({required bool enabled}) async {
    await _settingsService.setBool(SettingKeys.bellSound, value: enabled);
    state = enabled;
  }
}

/// Provider for bell sound with write capability.
final bellSoundNotifierProvider = NotifierProvider<BellSoundNotifier, bool>(
  BellSoundNotifier.new,
);

/// Notifier for terminal wake lock with write capability.
class TerminalWakeLockNotifier extends _AsyncSettingsNotifier<bool> {
  @override
  bool get _defaultValue => false;

  @override
  Future<bool> _loadValue() =>
      _settingsService.getBool(SettingKeys.terminalWakeLock);

  /// Set terminal wake lock enabled.
  Future<void> setEnabled({required bool enabled}) async {
    await _settingsService.setBool(
      SettingKeys.terminalWakeLock,
      value: enabled,
    );
    state = enabled;
  }
}

/// Provider for terminal wake lock with write capability.
final terminalWakeLockNotifierProvider =
    NotifierProvider<TerminalWakeLockNotifier, bool>(
      TerminalWakeLockNotifier.new,
    );

/// Notifier for terminal file path links with write capability.
class TerminalPathLinksNotifier extends _AsyncSettingsNotifier<bool> {
  @override
  bool get _defaultValue => true;

  @override
  Future<bool> _loadValue() => _settingsService.getBool(
    SettingKeys.terminalPathLinks,
    defaultValue: true,
  );

  /// Sets terminal file path linking.
  Future<void> setEnabled({required bool enabled}) async {
    await _settingsService.setBool(
      SettingKeys.terminalPathLinks,
      value: enabled,
    );
    state = enabled;
  }
}

/// Provider for terminal file path links with write capability.
final terminalPathLinksNotifierProvider =
    NotifierProvider<TerminalPathLinksNotifier, bool>(
      TerminalPathLinksNotifier.new,
    );

/// Notifier for terminal file path underlines with write capability.
class TerminalPathLinkUnderlinesNotifier extends _AsyncSettingsNotifier<bool> {
  @override
  bool get _defaultValue => true;

  @override
  Future<bool> _loadValue() => _settingsService.getBool(
    SettingKeys.terminalPathLinkUnderlines,
    defaultValue: true,
  );

  /// Sets terminal file path underlines.
  Future<void> setEnabled({required bool enabled}) async {
    await _settingsService.setBool(
      SettingKeys.terminalPathLinkUnderlines,
      value: enabled,
    );
    state = enabled;
  }
}

/// Provider for terminal file path underlines with write capability.
final terminalPathLinkUnderlinesNotifierProvider =
    NotifierProvider<TerminalPathLinkUnderlinesNotifier, bool>(
      TerminalPathLinkUnderlinesNotifier.new,
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
class TerminalThemeSettingsNotifier
    extends _AsyncSettingsNotifier<TerminalThemeSettings> {
  @override
  TerminalThemeSettings get _defaultValue => const TerminalThemeSettings(
    lightThemeId: TerminalThemes.defaultLightThemeId,
    darkThemeId: TerminalThemes.defaultDarkThemeId,
  );

  @override
  Future<TerminalThemeSettings> _loadValue() async {
    final light = await _settingsService.getString(
      SettingKeys.defaultTerminalThemeLight,
    );
    final dark = await _settingsService.getString(
      SettingKeys.defaultTerminalThemeDark,
    );
    final customThemeIds = await _getCustomTerminalThemeIds();
    final lightThemeId = _normalizeThemeId(
      light,
      brightness: Brightness.light,
      customThemeIds: customThemeIds,
    );
    final darkThemeId = _normalizeThemeId(
      dark,
      brightness: Brightness.dark,
      customThemeIds: customThemeIds,
    );
    if (_isDisposed) return state;
    await _persistNormalizedThemeId(
      key: SettingKeys.defaultTerminalThemeLight,
      storedThemeId: light,
      normalizedThemeId: lightThemeId,
    );
    await _persistNormalizedThemeId(
      key: SettingKeys.defaultTerminalThemeDark,
      storedThemeId: dark,
      normalizedThemeId: darkThemeId,
    );
    return TerminalThemeSettings(
      lightThemeId: lightThemeId,
      darkThemeId: darkThemeId,
    );
  }

  Future<Set<String>> _getCustomTerminalThemeIds() async {
    final json = await _settingsService.getString(
      SettingKeys.customTerminalThemes,
    );
    if (json == null || json.isEmpty) {
      return const {};
    }

    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) {
        return const {};
      }

      final themeIds = <String>{};
      for (final item in decoded) {
        final theme = TerminalThemeData.tryFromJson(item);
        if (theme != null) {
          themeIds.add(theme.id);
        }
      }
      return themeIds;
    } on FormatException {
      return const {};
    }
  }

  String _normalizeThemeId(
    String? themeId, {
    required Brightness brightness,
    required Set<String> customThemeIds,
  }) {
    final defaultThemeId = TerminalThemes.defaultThemeIdForBrightness(
      brightness,
    );
    if (themeId == null || themeId.isEmpty) {
      return defaultThemeId;
    }
    if (customThemeIds.contains(themeId)) {
      return themeId;
    }
    final resolvedThemeId = TerminalThemes.resolveThemeId(themeId);
    if (TerminalThemes.getById(resolvedThemeId) != null) {
      return resolvedThemeId;
    }
    return defaultThemeId;
  }

  Future<void> _persistNormalizedThemeId({
    required String key,
    required String? storedThemeId,
    required String normalizedThemeId,
  }) async {
    if (storedThemeId != null && storedThemeId != normalizedThemeId) {
      await _settingsService.setString(key, normalizedThemeId);
    }
  }

  /// Set the light mode theme.
  Future<void> setLightTheme(String themeId) async {
    await _settingsService.setString(
      SettingKeys.defaultTerminalThemeLight,
      themeId,
    );
    state = state.copyWith(lightThemeId: themeId);
  }

  /// Set the dark mode theme.
  Future<void> setDarkTheme(String themeId) async {
    await _settingsService.setString(
      SettingKeys.defaultTerminalThemeDark,
      themeId,
    );
    state = state.copyWith(darkThemeId: themeId);
  }
}

/// Provider for terminal theme settings.
final terminalThemeSettingsProvider =
    NotifierProvider<TerminalThemeSettingsNotifier, TerminalThemeSettings>(
      TerminalThemeSettingsNotifier.new,
    );

/// Provider for shared clipboard setting.
final sharedClipboardProvider = FutureProvider<bool>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  return settings.getBool(SettingKeys.sharedClipboard);
});

/// Provider for local clipboard read sharing setting.
final sharedClipboardLocalReadProvider = FutureProvider<bool>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  return settings.getBool(SettingKeys.sharedClipboardLocalRead);
});

/// Notifier for shared clipboard remote-to-local writes.
class SharedClipboardNotifier extends _AsyncSettingsNotifier<bool> {
  @override
  bool get _defaultValue => false;

  @override
  Future<bool> _loadValue() =>
      _settingsService.getBool(SettingKeys.sharedClipboard);

  /// Set shared clipboard enabled.
  Future<void> setEnabled({required bool enabled}) async {
    await _settingsService.setBool(SettingKeys.sharedClipboard, value: enabled);
    state = enabled;
  }
}

/// Provider for shared clipboard setting with write capability.
final sharedClipboardNotifierProvider =
    NotifierProvider<SharedClipboardNotifier, bool>(
      SharedClipboardNotifier.new,
    );

/// Notifier for local clipboard reads from the remote side.
class SharedClipboardLocalReadNotifier extends _AsyncSettingsNotifier<bool> {
  @override
  bool get _defaultValue => false;

  @override
  Future<bool> _loadValue() =>
      _settingsService.getBool(SettingKeys.sharedClipboardLocalRead);

  /// Set whether the remote side can read the local clipboard.
  Future<void> setEnabled({required bool enabled}) async {
    await _settingsService.setBool(
      SettingKeys.sharedClipboardLocalRead,
      value: enabled,
    );
    state = enabled;
  }
}

/// Provider for local clipboard read sharing with write capability.
final sharedClipboardLocalReadNotifierProvider =
    NotifierProvider<SharedClipboardLocalReadNotifier, bool>(
      SharedClipboardLocalReadNotifier.new,
    );

/// Notifier for tap-to-show-keyboard with write capability.
class TapToShowKeyboardNotifier extends _AsyncSettingsNotifier<bool> {
  @override
  bool get _defaultValue => true;

  @override
  Future<bool> _loadValue() => _settingsService.getBool(
    SettingKeys.tapToShowKeyboard,
    defaultValue: true,
  );

  /// Set tap-to-show-keyboard enabled.
  Future<void> setEnabled({required bool enabled}) async {
    await _settingsService.setBool(
      SettingKeys.tapToShowKeyboard,
      value: enabled,
    );
    state = enabled;
  }
}

/// Provider for tap-to-show-keyboard setting with write capability.
final tapToShowKeyboardNotifierProvider =
    NotifierProvider<TapToShowKeyboardNotifier, bool>(
      TapToShowKeyboardNotifier.new,
    );
