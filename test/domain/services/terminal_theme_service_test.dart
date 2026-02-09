// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/terminal_theme_service.dart';

void main() {
  late AppDatabase db;
  late SettingsService settingsService;
  late TerminalThemeService themeService;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    settingsService = SettingsService(db);
    themeService = TerminalThemeService(settingsService);
  });

  tearDown(() async {
    await db.close();
  });

  group('TerminalThemeService', () {
    group('getThemeForHost', () {
      test('returns built-in dark default when no host', () async {
        final theme = await themeService.getThemeForHost(null, Brightness.dark);
        expect(theme.id, TerminalThemes.midnightPurple.id);
      });

      test('returns built-in light default when no host', () async {
        final theme = await themeService.getThemeForHost(
          null,
          Brightness.light,
        );
        expect(theme.id, TerminalThemes.cleanWhite.id);
      });
    });

    group('getThemeById', () {
      test('returns built-in theme by id', () async {
        final theme = await themeService.getThemeById('midnight-purple');
        expect(theme, isNotNull);
        expect(theme!.name, 'Midnight Purple');
      });

      test('returns null for unknown id', () async {
        final theme = await themeService.getThemeById('nonexistent-theme');
        expect(theme, isNull);
      });
    });

    group('getAllThemes', () {
      test('returns all built-in themes', () async {
        final themes = await themeService.getAllThemes();
        expect(themes.length, TerminalThemes.all.length);
      });
    });

    group('getDarkThemes', () {
      test('returns only dark themes', () async {
        final themes = await themeService.getDarkThemes();
        expect(themes, isNotEmpty);
        for (final theme in themes) {
          expect(theme.isDark, isTrue);
        }
      });
    });

    group('getLightThemes', () {
      test('returns only light themes', () async {
        final themes = await themeService.getLightThemes();
        expect(themes, isNotEmpty);
        for (final theme in themes) {
          expect(theme.isDark, isFalse);
        }
      });
    });

    group('getCustomThemes', () {
      test('returns empty list initially', () async {
        final themes = await themeService.getCustomThemes();
        expect(themes, isEmpty);
      });
    });

    group('saveCustomTheme', () {
      test('saves and retrieves a custom theme', () async {
        final theme = TerminalThemes.midnightPurple.copyWith(
          id: 'custom-test',
          name: 'Custom Test',
          isCustom: true,
        );

        await themeService.saveCustomTheme(theme);

        final customs = await themeService.getCustomThemes();
        expect(customs, hasLength(1));
        expect(customs.first.id, 'custom-test');
        expect(customs.first.name, 'Custom Test');
      });

      test('updates existing custom theme', () async {
        final theme = TerminalThemes.midnightPurple.copyWith(
          id: 'custom-update',
          name: 'Original',
          isCustom: true,
        );
        await themeService.saveCustomTheme(theme);

        final updated = theme.copyWith(name: 'Updated');
        await themeService.saveCustomTheme(updated);

        final customs = await themeService.getCustomThemes();
        expect(customs, hasLength(1));
        expect(customs.first.name, 'Updated');
      });
    });

    group('deleteCustomTheme', () {
      test('deletes a custom theme', () async {
        final theme = TerminalThemes.midnightPurple.copyWith(
          id: 'custom-delete',
          name: 'To Delete',
          isCustom: true,
        );
        await themeService.saveCustomTheme(theme);
        expect(await themeService.getCustomThemes(), hasLength(1));

        await themeService.deleteCustomTheme('custom-delete');

        final customs = await themeService.getCustomThemes();
        expect(customs, isEmpty);
      });
    });
  });
}
