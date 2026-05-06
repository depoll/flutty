import 'dart:async';

// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import 'package:monkeyssh/app/app_metadata.dart';
import 'package:monkeyssh/app/routes.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
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

class _SupportedButUnavailableAuthService extends FakeAuthService {
  @override
  Future<BiometricAvailability> getBiometricAvailability() async =>
      const BiometricAvailability(
        isDeviceAuthSupported: true,
        isBiometricHardwareSupported: true,
        enrolledBiometrics: [],
      );
}

class _ToggleableBiometricAuthService extends FakeAuthService {
  bool biometricEnabled = false;

  @override
  Future<bool> isAuthEnabled() async => true;

  @override
  Future<bool> isDeviceAuthSupported() async => true;

  @override
  Future<bool> isBiometricHardwareSupported() async => true;

  @override
  Future<bool> isBiometricAvailable() async => true;

  @override
  Future<bool> isBiometricEnabled() async => biometricEnabled;

  @override
  Future<BiometricAvailability> getBiometricAvailability() async =>
      const BiometricAvailability(
        isDeviceAuthSupported: true,
        isBiometricHardwareSupported: true,
        enrolledBiometrics: [BiometricType.fingerprint],
      );

  @override
  Future<void> setBiometricEnabled({required bool enabled}) async {
    biometricEnabled = enabled;
  }
}

class _UnlockedAuthStateNotifier extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.unlocked;
}

class _UnknownAuthStateNotifier extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.unknown;
}

class _ChangePinAuthService extends FakeAuthService {
  bool shouldSucceed = false;
  int changePinCallCount = 0;

  @override
  Future<bool> changePin(String currentPin, String newPin) async {
    changePinCallCount += 1;
    return shouldSucceed;
  }
}

class _ThrowingChangePinAuthService extends FakeAuthService {
  @override
  Future<bool> changePin(String currentPin, String newPin) async {
    throw Exception('storage unavailable');
  }
}

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
      expect(
        find.text('Subscription status and Pro-only workflows'),
        findsOneWidget,
      );
      expect(find.text('Subscription'), findsOneWidget);
      expect(
        find.text('Unlock transfers, automation, and agent launch presets'),
        findsOneWidget,
      );
    });

    testWidgets('toggles shell completion popups from terminal settings', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      await tester.scrollUntilVisible(
        find.text('Shell completion popups'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      final tile = find.widgetWithText(
        SwitchListTile,
        'Shell completion popups',
      );
      expect(tile, findsOneWidget);

      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(
        await SettingsService(
          db,
        ).getBool(SettingKeys.shellCompletions, defaultValue: true),
        isFalse,
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
        MonetizationProductIds.iosProLifetimeProd,
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
      expect(find.text('Use terminal themes for app'), findsOneWidget);
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

    testWidgets('displays terminal wake lock toggle', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      await tester.scrollUntilVisible(
        find.text('Keep screen awake'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      expect(find.text('Keep screen awake'), findsOneWidget);
      expect(
        find.text('Hold a wake lock while a terminal is active'),
        findsOneWidget,
      );
    });

    testWidgets('displays terminal path link toggles', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      await tester.scrollUntilVisible(
        find.text('Clickable file paths'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

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

    testWidgets('shows security setup actions when auth is not configured', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _pumpSettingsScreen(tester, db: db);

      expect(find.text('Set up app lock'), findsOneWidget);
      expect(find.text('Biometric authentication'), findsOneWidget);
      expect(find.text('Auto-lock timeout'), findsOneWidget);
      expect(find.text('Change PIN'), findsNothing);
      expect(find.text('Set up app lock first'), findsOneWidget);
      expect(
        find.text('Biometric hardware not supported on this device'),
        findsOneWidget,
      );
    });

    testWidgets('keeps setup actions disabled while auth state is loading', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(_UnknownAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      final setupTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Set up app lock'),
      );
      expect(setupTile.onTap, isNull);
      expect(find.text('Checking security status'), findsNWidgets(3));
    });

    testWidgets('navigates to auth setup from the settings entry point', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/auth-setup',
            name: Routes.authSetup,
            builder: (context, state) =>
                const Scaffold(body: Text('Auth setup destination')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(FakeAuthService()),
            authStateProvider.overrideWith(MockAuthStateNotifier.new),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );

      await tester.pumpAndSettle();

      await tester.tap(find.text('Set up app lock'));
      await tester.pumpAndSettle();

      expect(find.text('Auth setup destination'), findsOneWidget);
    });

    testWidgets(
      'disables biometric toggle when support exists but enrollment is missing',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              authServiceProvider.overrideWithValue(
                _SupportedButUnavailableAuthService(),
              ),
              authStateProvider.overrideWith(MockAuthStateNotifier.new),
            ],
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );

        await tester.pumpAndSettle();

        expect(find.text('Biometric authentication'), findsOneWidget);
        final biometricTile = find.widgetWithText(
          SwitchListTile,
          'Biometric authentication',
        );
        expect(biometricTile, findsOneWidget);
        final tile = tester.widget<SwitchListTile>(biometricTile);
        expect(tile.value, isFalse);
        expect(tile.onChanged, isNull);
        expect(
          find.text(
            'Enroll fingerprint or face in system settings before enabling',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('shows biometric re-check action after enrollment guidance', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(
              _SupportedButUnavailableAuthService(),
            ),
            authStateProvider.overrideWith(_UnlockedAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      final biometricTile = find.widgetWithText(
        SwitchListTile,
        'Biometric authentication',
      );
      final tile = tester.widget<SwitchListTile>(biometricTile);
      expect(tile.onChanged, isNull);
      expect(
        find.text(
          'Enroll fingerprint or face in system settings, then return and re-check',
        ),
        findsOneWidget,
      );
      expect(find.text('Re-check biometric status'), findsOneWidget);
    });

    testWidgets('updates biometric toggle state immediately after tapping', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final authService = _ToggleableBiometricAuthService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(authService),
            authStateProvider.overrideWith(_UnlockedAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      final biometricTile = find.widgetWithText(
        SwitchListTile,
        'Biometric authentication',
      );
      expect(tester.widget<SwitchListTile>(biometricTile).value, isFalse);

      tester.widget<SwitchListTile>(biometricTile).onChanged!(true);
      await tester.pumpAndSettle();

      expect(authService.biometricEnabled, isTrue);
      expect(tester.widget<SwitchListTile>(biometricTile).value, isTrue);
      expect(find.text('Use fingerprint or face to unlock'), findsOneWidget);
    });

    testWidgets(
      'keeps change PIN dialog open when the current PIN is incorrect',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final authService = _ChangePinAuthService();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              authServiceProvider.overrideWithValue(authService),
              authStateProvider.overrideWith(_UnlockedAuthStateNotifier.new),
            ],
            child: const MaterialApp(home: SettingsScreen()),
          ),
        );

        await tester.pumpAndSettle();

        await tester.tap(find.text('Change PIN'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Current PIN'),
          '0000',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'New PIN'),
          '123456',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Confirm new PIN'),
          '123456',
        );

        await tester.tap(find.widgetWithText(FilledButton, 'Change'));
        await tester.pumpAndSettle();

        expect(authService.changePinCallCount, 1);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('Current PIN is incorrect'), findsOneWidget);
        expect(find.text('PIN changed successfully'), findsNothing);
      },
    );

    testWidgets('recovers the change PIN dialog after unexpected failures', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final reportedErrors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = originalOnError);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(
              _ThrowingChangePinAuthService(),
            ),
            authStateProvider.overrideWith(_UnlockedAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      await tester.tap(find.text('Change PIN'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Current PIN'),
        '1234',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'New PIN'),
        '567890',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm new PIN'),
        '567890',
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Change'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Could not change PIN. Try again.'), findsOneWidget);
      expect(reportedErrors, hasLength(1));
      final cancelButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Cancel'),
      );
      expect(cancelButton.onPressed, isNotNull);
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
            terminalThemesApplyToAppNotifierProvider.overrideWith(
              StaticTerminalThemesApplyToAppNotifier.new,
            ),
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
