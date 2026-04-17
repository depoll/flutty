import 'dart:async';

// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/app/app_metadata.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/domain/services/background_ssh_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/screens/settings_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../support/settings_import_test_helpers.dart';

const _backgroundSshChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/ssh_service',
);

Future<void> _pumpSettingsScreen(
  WidgetTester tester, {
  required AppDatabase db,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authServiceProvider.overrideWithValue(FakeAuthService()),
        authStateProvider.overrideWith(MockAuthStateNotifier.new),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );

  await tester.pumpAndSettle();
}

void main() {
  group('SettingsScreen', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'MonkeySSH',
        packageName: 'xyz.depollsoft.monkeyssh',
        version: '0.1.1',
        buildNumber: '123',
        buildSignature: '',
      );
      BackgroundSshService.debugIsAndroidPlatformOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _backgroundSshChannel,
            (call) async => switch (call.method) {
              'isBatteryOptimizationIgnored' => false,
              'requestDisableBatteryOptimization' => true,
              _ => null,
            },
          );
    });

    tearDown(() {
      BackgroundSshService.debugIsAndroidPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, null);
    });

    testWidgets('displays all sections', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Terminal'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Terminal'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Import & Export'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Import & Export'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Background SSH'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Background SSH'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('About'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('About'), findsOneWidget);
    });

    testWidgets('displays MonkeySSH Pro subscription section', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      expect(find.text('MonkeySSH Pro'), findsOneWidget);
      expect(find.text('Subscription'), findsOneWidget);
      expect(
        find.text('Unlock transfers, automation, and agent launch presets'),
        findsOneWidget,
      );
    });

    testWidgets('shows active subscription state when Pro is unlocked', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await SettingsService(
        db,
      ).setBool(SettingKeys.monetizationProUnlocked, value: true);

      await _pumpSettingsScreen(tester, db: db);

      expect(find.text('Unlocked on this device'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
    });

    testWidgets('shows lifetime state when Pro is unlocked via lifetime SKU', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final settings = SettingsService(db);
      await settings.setBool(SettingKeys.monetizationProUnlocked, value: true);
      await settings.setString(
        SettingKeys.monetizationActiveProductId,
        'monkeyssh_pro_lifetime_prod',
      );

      await _pumpSettingsScreen(tester, db: db);

      expect(find.text('Lifetime — unlocked on this device'), findsOneWidget);
      expect(find.text('Lifetime'), findsOneWidget);
    });

    testWidgets('displays theme option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('System default'), findsOneWidget);
    });

    testWidgets('displays font size option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      await tester.scrollUntilVisible(
        find.text('Font size'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Font size'), findsOneWidget);
      expect(find.text('14 pt'), findsOneWidget);
    });

    testWidgets('displays font family option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      await tester.scrollUntilVisible(
        find.text('Font family'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Font family'), findsOneWidget);
      expect(find.text('System Monospace'), findsOneWidget);
    });

    testWidgets('displays cursor style option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      await tester.scrollUntilVisible(
        find.text('Cursor style'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Cursor style'), findsOneWidget);
      expect(find.text('Block'), findsOneWidget);
    });

    testWidgets('displays bell sound toggle', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      await tester.scrollUntilVisible(
        find.text('Bell sound'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Bell sound'), findsOneWidget);
      expect(find.text('Play sound on terminal bell'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsWidgets);
    });

    testWidgets('displays terminal path link toggles', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      expect(find.text('Clickable file paths'), findsOneWidget);
      expect(
        find.text('Tap terminal file paths to open them in SFTP'),
        findsOneWidget,
      );
      expect(find.text('Path link underlines'), findsOneWidget);
      expect(
        find.text('Underline clickable terminal file paths'),
        findsOneWidget,
      );
    });

    testWidgets('displays about section with version', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appMetadataProvider.overrideWith(
              (ref) async => const AppMetadata(
                appName: 'MonkeySSH',
                version: '0.1.1',
                buildNumber: '123',
                versionCodename: 'Allen\'s Swamp Monkey',
              ),
            ),
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('App version'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('App version'), findsOneWidget);
      expect(find.text('0.1.1 "Allen\'s Swamp Monkey" (123)'), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Licenses'), findsOneWidget);
    });

    testWidgets('displays preview metadata when available', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appMetadataProvider.overrideWith(
              (ref) async => const AppMetadata(
                appName: 'MonkeySSH',
                version: '0.1.1',
                buildNumber: '123',
                versionCodename: 'Allen\'s Swamp Monkey',
                pullRequestNumber: '175',
                pullRequestTitle: 'Show PR metadata in settings',
              ),
            ),
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Preview build'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Preview build'), findsOneWidget);
      expect(
        find.text('PR #175: Show PR metadata in settings'),
        findsOneWidget,
      );
    });

    testWidgets('displays security options', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      expect(find.text('Change PIN'), findsOneWidget);
      expect(find.text('Biometric authentication'), findsOneWidget);
      expect(find.text('Auto-lock timeout'), findsOneWidget);
    });

    testWidgets('displays Android background reliability controls', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      await tester.scrollUntilVisible(
        find.text('Battery optimization'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Background SSH'), findsOneWidget);
      expect(find.text('Battery optimization'), findsOneWidget);
      expect(find.text('Enabled'), findsOneWidget);
      expect(
        find.textContaining(
          'Foreground notifications alone are not always enough on Android.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows loading state before battery optimization resolves', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final completer = Completer<bool?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _backgroundSshChannel,
            (call) => switch (call.method) {
              'isBatteryOptimizationIgnored' => completer.future,
              'requestDisableBatteryOptimization' => Future<bool>.value(true),
              _ => Future<Object?>.value(),
            },
          );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pump();

      await tester.scrollUntilVisible(
        find.text('Battery optimization'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();

      final batteryOptimizationTile = find.widgetWithText(
        ListTile,
        'Battery optimization',
      );
      expect(
        find.descendant(
          of: batteryOptimizationTile,
          matching: find.text('Loading...'),
        ),
        findsOneWidget,
      );
      expect(
        find.text('Checking Android battery optimization status...'),
        findsOneWidget,
      );
      final tile = tester.widget<ListTile>(batteryOptimizationTile);
      expect(tile.onTap, isNull);

      completer.complete(false);
      await tester.pumpAndSettle();
    });

    testWidgets('shows unavailable state when battery status cannot be read', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _backgroundSshChannel,
            (call) async => switch (call.method) {
              'isBatteryOptimizationIgnored' => throw PlatformException(
                code: 'failed',
              ),
              'requestDisableBatteryOptimization' => true,
              _ => null,
            },
          );

      await _pumpSettingsScreen(tester, db: db);

      await tester.scrollUntilVisible(
        find.text('Battery optimization'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Unavailable'), findsOneWidget);
      expect(
        find.text('Could not determine battery optimization status right now.'),
        findsOneWidget,
      );
      final tile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Battery optimization'),
      );
      expect(tile.onTap, isNull);
    });

    testWidgets('displays import and export actions', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      await tester.scrollUntilVisible(
        find.text('Export app data'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Export app data'), findsOneWidget);
      expect(find.text('Import app data'), findsOneWidget);
    });

    testWidgets('has scrollable ListView', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      expect(find.byType(ListView), findsOneWidget);
    });

    testWidgets('import app data invalidates shared entity providers', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      var hostBuilds = 0;
      var keyBuilds = 0;
      var groupBuilds = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
            themeModeNotifierProvider.overrideWith(StaticThemeModeNotifier.new),
            fontSizeNotifierProvider.overrideWith(StaticFontSizeNotifier.new),
            fontFamilyNotifierProvider.overrideWith(
              StaticFontFamilyNotifier.new,
            ),
            cursorStyleNotifierProvider.overrideWith(
              StaticCursorStyleNotifier.new,
            ),
            bellSoundNotifierProvider.overrideWith(StaticBellSoundNotifier.new),
            terminalThemeSettingsProvider.overrideWith(
              StaticTerminalThemeSettingsNotifier.new,
            ),
            allHostsProvider.overrideWith((ref) {
              hostBuilds += 1;
              return Stream.value(<Host>[]);
            }),
            allKeysProvider.overrideWith((ref) {
              keyBuilds += 1;
              return Stream.value(<SshKey>[]);
            }),
            allGroupsProvider.overrideWith((ref) {
              groupBuilds += 1;
              return Stream.value(<Group>[]);
            }),
          ],
          child: const MaterialApp(
            home: Stack(children: [SettingsScreen(), EntityProviderProbe()]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final initialHostBuilds = hostBuilds;
      final initialKeyBuilds = keyBuilds;
      final initialGroupBuilds = groupBuilds;
      final container = ProviderScope.containerOf(
        tester.element(find.byType(EntityProviderProbe)),
      );

      invalidateImportedEntityProviders(container.invalidate);
      container
        ..read(allHostsProvider)
        ..read(allKeysProvider)
        ..read(allGroupsProvider);
      await tester.pump();

      expect(hostBuilds, greaterThan(initialHostBuilds));
      expect(keyBuilds, greaterThan(initialKeyBuilds));
      expect(groupBuilds, greaterThan(initialGroupBuilds));
    });
  });
}
