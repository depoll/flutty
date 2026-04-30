// ignore_for_file: implementation_imports, public_member_api_docs

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart' as monkey_themes;
import 'package:monkeyssh/domain/services/host_key_prompt_handler_provider.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

const _sshPort = int.fromEnvironment('CODEX_THEME_SSH_PORT');
const _sshUser = String.fromEnvironment('CODEX_THEME_SSH_USER');
const _sshPrivateKeyBase64 = String.fromEnvironment('CODEX_THEME_SSH_KEY_B64');
const _sshPublicKeyBase64 = String.fromEnvironment('CODEX_THEME_SSH_PUB_B64');
const _tmuxSessionName = String.fromEnvironment('CODEX_THEME_TMUX_SESSION');
const _tmuxWorkingDirectory = String.fromEnvironment('CODEX_THEME_WORKDIR');

bool get _hasValidationEnvironment =>
    _sshPort > 0 &&
    _sshUser.isNotEmpty &&
    _sshPrivateKeyBase64.isNotEmpty &&
    _sshPublicKeyBase64.isNotEmpty &&
    _tmuxSessionName.isNotEmpty &&
    _tmuxWorkingDirectory.isNotEmpty;

String get _deviceReachableHost =>
    Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';

MonetizationState _proMonetizationState() => const MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Codex input remains readable after tmux theme switches', (
    tester,
  ) async {
    if (!_hasValidationEnvironment) {
      markTestSkipped('CODEX_THEME_* dart-defines are not configured.');
      return;
    }

    expect(_sshPort, greaterThan(0));
    expect(_sshUser, isNotEmpty);
    expect(_sshPrivateKeyBase64, isNotEmpty);
    expect(_sshPublicKeyBase64, isNotEmpty);
    expect(_tmuxSessionName, isNotEmpty);
    expect(_tmuxWorkingDirectory, isNotEmpty);

    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final encryptionService = SecretEncryptionService.forTesting();
    final hostRepository = HostRepository(db, encryptionService);
    final keyRepository = KeyRepository(db, encryptionService);

    final keyId = await keyRepository.insert(
      SshKeysCompanion.insert(
        name: 'Codex theme validation key',
        keyType: 'ed25519',
        publicKey: utf8.decode(base64Decode(_sshPublicKeyBase64)),
        privateKey: utf8.decode(base64Decode(_sshPrivateKeyBase64)),
        passphrase: const Value(null),
        fingerprint: const Value('codex-theme-validation'),
      ),
    );

    final hostId = await hostRepository.insert(
      HostsCompanion.insert(
        label: 'Codex theme validation',
        hostname: _deviceReachableHost,
        port: const Value(_sshPort),
        username: _sshUser,
        keyId: Value(keyId),
        password: const Value(null),
        autoConnectRequiresConfirmation: const Value(false),
        terminalThemeLightId: const Value('clean-white'),
        terminalThemeDarkId: const Value('ocean-dark'),
        tmuxSessionName: const Value(_tmuxSessionName),
        tmuxWorkingDirectory: const Value(_tmuxWorkingDirectory),
      ),
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secretEncryptionServiceProvider.overrideWithValue(encryptionService),
        hostKeyPromptHandlerProvider.overrideWithValue(
          (_) async => HostKeyTrustDecision.trust,
        ),
        monetizationStateProvider.overrideWith(
          (ref) => Stream<MonetizationState>.value(_proMonetizationState()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final themeMode = ValueNotifier(ThemeMode.light);
    addTearDown(themeMode.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: themeMode,
          builder: (context, mode, child) => MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            home: child,
          ),
          child: TerminalScreen(hostId: hostId),
        ),
      ),
    );

    await _pumpUntilConnected(tester);
    await _pumpUntilFound(tester, find.byType(MonkeyTerminalView));

    final terminal = _terminalFromView(tester);
    await _waitForTerminalText(
      tester,
      terminal,
      'Codex',
      description: 'Timed out waiting for Codex to render in tmux',
      timeout: const Duration(seconds: 90),
    );
    await _pumpUntil(
      tester,
      () => terminal.reportFocusMode,
      description: 'Codex/tmux did not request terminal focus reports',
    );

    await _switchThemeMode(tester, themeMode, ThemeMode.dark);
    const darkToken = 'dark-visible-token';
    terminal.textInput(darkToken);
    await _waitForTerminalText(
      tester,
      terminal,
      darkToken,
      description: 'Timed out waiting for dark-theme Codex input token',
    );
    final darkContrast = _minimumTokenContrast(
      terminal,
      monkey_themes.TerminalThemes.oceanDark,
      darkToken,
    );
    expect(darkContrast, greaterThanOrEqualTo(4.5));
    await binding.takeScreenshot('codex-ocean-dark-readable');

    await _switchThemeMode(tester, themeMode, ThemeMode.light);
    const lightToken = '-light-visible-token';
    terminal.textInput(lightToken);
    await _waitForTerminalText(
      tester,
      terminal,
      lightToken,
      description: 'Timed out waiting for light-theme Codex input token',
    );
    final lightContrast = _minimumTokenContrast(
      terminal,
      monkey_themes.TerminalThemes.cleanWhite,
      lightToken,
    );
    expect(lightContrast, greaterThanOrEqualTo(4.5));
    await binding.takeScreenshot('codex-clean-white-readable');
  });
}

Future<void> _pumpUntilConnected(WidgetTester tester) async {
  await _pumpUntil(
    tester,
    () => find.text('Connecting...').evaluate().isEmpty,
    description: 'SSH connection to validation host',
    timeout: const Duration(seconds: 60),
  );
  expect(find.textContaining('Failed to start shell'), findsNothing);
  expect(find.textContaining('Connection failed'), findsNothing);
}

Future<void> _switchThemeMode(
  WidgetTester tester,
  ValueNotifier<ThemeMode> themeMode,
  ThemeMode mode,
) async {
  themeMode.value = mode;
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

Terminal _terminalFromView(WidgetTester tester) =>
    tester.widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView)).terminal;

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  await _pumpUntil(
    tester,
    () => finder.evaluate().isNotEmpty,
    description: 'finder $finder',
    timeout: timeout,
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(step);
    if (predicate()) {
      return;
    }
  }
  fail('Timed out waiting for $description');
}

Future<void> _waitForTerminalText(
  WidgetTester tester,
  Terminal terminal,
  String expected, {
  required String description,
  Duration timeout = const Duration(seconds: 20),
}) async {
  await _pumpUntil(
    tester,
    () => _terminalBufferText(terminal).contains(expected),
    description: '$description\n${_terminalBufferText(terminal)}',
    timeout: timeout,
  );
}

String _terminalBufferText(Terminal terminal) {
  final lines = <String>[];
  for (var index = 0; index < terminal.buffer.lines.length; index += 1) {
    lines.add(
      terminal.buffer.lines[index]
          .getText(0, terminal.buffer.viewWidth)
          .trimRight(),
    );
  }
  return lines.join('\n');
}

double _minimumTokenContrast(
  Terminal terminal,
  TerminalThemeData theme,
  String token,
) {
  final xtermTheme = theme.toXtermTheme();
  final palette = PaletteBuilder(xtermTheme).build();
  final cell = CellData.empty();

  for (var row = 0; row < terminal.buffer.lines.length; row += 1) {
    final line = terminal.buffer.lines[row];
    final text = line.getText(0, terminal.buffer.viewWidth);
    final startColumn = text.indexOf(token);
    if (startColumn == -1) {
      continue;
    }

    var minimum = double.infinity;
    for (var offset = 0; offset < token.length; offset += 1) {
      line.getCellData(startColumn + offset, cell);
      final colors = _effectiveCellColors(cell, xtermTheme, palette);
      minimum = math.min(
        minimum,
        _contrastRatio(colors.foreground, colors.background),
      );
    }
    return minimum;
  }

  fail('Could not find token "$token" in terminal buffer.');
}

({Color foreground, Color background}) _effectiveCellColors(
  CellData cell,
  TerminalTheme xtermTheme,
  List<Color> palette,
) {
  var foreground = (cell.flags & CellFlags.inverse) == 0
      ? _resolveForegroundColor(cell.foreground, xtermTheme, palette)
      : _resolveBackgroundColor(cell.background, xtermTheme, palette);
  final background = (cell.flags & CellFlags.inverse) == 0
      ? _resolveBackgroundColor(cell.background, xtermTheme, palette)
      : _resolveForegroundColor(cell.foreground, xtermTheme, palette);

  if ((cell.flags & CellFlags.faint) != 0) {
    foreground = Color.alphaBlend(foreground.withAlpha(128), background);
  }
  return (foreground: foreground, background: background);
}

Color _resolveForegroundColor(
  int cellColor,
  TerminalTheme xtermTheme,
  List<Color> palette,
) {
  final colorType = cellColor & CellColor.typeMask;
  final colorValue = cellColor & CellColor.valueMask;
  return switch (colorType) {
    CellColor.normal => xtermTheme.foreground,
    CellColor.named || CellColor.palette => palette[colorValue],
    _ => Color.fromARGB(
      0xFF,
      (colorValue >> 16) & 0xFF,
      (colorValue >> 8) & 0xFF,
      colorValue & 0xFF,
    ),
  };
}

Color _resolveBackgroundColor(
  int cellColor,
  TerminalTheme xtermTheme,
  List<Color> palette,
) {
  final colorType = cellColor & CellColor.typeMask;
  final colorValue = cellColor & CellColor.valueMask;
  return switch (colorType) {
    CellColor.normal => xtermTheme.background,
    CellColor.named || CellColor.palette => palette[colorValue],
    _ => Color.fromARGB(
      0xFF,
      (colorValue >> 16) & 0xFF,
      (colorValue >> 8) & 0xFF,
      colorValue & 0xFF,
    ),
  };
}

double _contrastRatio(Color a, Color b) {
  final luminanceA = a.computeLuminance();
  final luminanceB = b.computeLuminance();
  final brightest = math.max(luminanceA, luminanceB);
  final darkest = math.min(luminanceA, luminanceB);
  return (brightest + 0.05) / (darkest + 0.05);
}
