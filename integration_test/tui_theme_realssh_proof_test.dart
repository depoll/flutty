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
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart' hide TerminalThemes;

const _sshPort = int.fromEnvironment('TUI_THEME_PROOF_SSH_PORT');
const _sshUser = String.fromEnvironment('TUI_THEME_PROOF_SSH_USER');
const _sshPrivateKeyBase64 = String.fromEnvironment(
  'TUI_THEME_PROOF_SSH_KEY_B64',
);
const _sshPublicKeyBase64 = String.fromEnvironment(
  'TUI_THEME_PROOF_SSH_PUB_B64',
);
const _workdir = String.fromEnvironment('TUI_THEME_PROOF_WORKDIR');
const _codexPlainCommand = String.fromEnvironment(
  'TUI_THEME_PROOF_CODEX_PLAIN_COMMAND',
);
const _opencodePlainCommand = String.fromEnvironment(
  'TUI_THEME_PROOF_OPENCODE_PLAIN_COMMAND',
);
const _codexTmuxSession = String.fromEnvironment(
  'TUI_THEME_PROOF_CODEX_TMUX_SESSION',
);
const _opencodeTmuxSession = String.fromEnvironment(
  'TUI_THEME_PROOF_OPENCODE_TMUX_SESSION',
);

bool get _hasValidationEnvironment =>
    _sshPort > 0 &&
    _sshUser.isNotEmpty &&
    _sshPrivateKeyBase64.isNotEmpty &&
    _sshPublicKeyBase64.isNotEmpty &&
    _workdir.isNotEmpty &&
    _codexPlainCommand.isNotEmpty &&
    _opencodePlainCommand.isNotEmpty &&
    _codexTmuxSession.isNotEmpty &&
    _opencodeTmuxSession.isNotEmpty;

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

  for (final proofCase in const [
    _ProofCase(
      id: 'codex-plain',
      label: 'Codex plain',
      expectedText: 'OpenAI Codex',
      tokenPrefix: 'cp',
      startupCommand: _codexPlainCommand,
    ),
    _ProofCase(
      id: 'codex-tmux',
      label: 'Codex tmux',
      expectedText: 'OpenAI Codex',
      tokenPrefix: 'ct',
      tmuxSessionName: _codexTmuxSession,
    ),
    _ProofCase(
      id: 'opencode-plain',
      label: 'OpenCode plain',
      expectedText: 'OpenCode Zen',
      tokenPrefix: 'op',
      startupCommand: _opencodePlainCommand,
    ),
    _ProofCase(
      id: 'opencode-tmux',
      label: 'OpenCode tmux',
      expectedText: 'OpenCode Zen',
      tokenPrefix: 'ot',
      tmuxSessionName: _opencodeTmuxSession,
    ),
  ]) {
    testWidgets('${proofCase.label} follows light and dark terminal themes', (
      tester,
    ) async {
      if (!_hasValidationEnvironment) {
        markTestSkipped('TUI_THEME_PROOF_* dart-defines are not configured.');
        return;
      }

      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
      }

      final terminal = await _pumpProofTerminal(tester, proofCase);
      if (proofCase.startupCommand != null) {
        await tester.pump(const Duration(seconds: 1));
        _terminalFromView(tester).textInput('${proofCase.startupCommand}\r');
      }
      await _waitForTerminalText(
        tester,
        () => _terminalFromView(tester),
        proofCase.expectedText,
        description: 'Timed out waiting for ${proofCase.label}',
        timeout: const Duration(seconds: 90),
      );
      await binding.takeScreenshot('${proofCase.id}-light-before');

      final suffix = DateTime.now().millisecondsSinceEpoch
          .remainder(46656)
          .toRadixString(36);

      await _switchThemeMode(tester, terminal.container, ThemeMode.dark);
      final darkToken = '${proofCase.tokenPrefix}d$suffix';
      _terminalFromView(tester).textInput(darkToken);
      await _waitForTerminalText(
        tester,
        () => _terminalFromView(tester),
        darkToken,
        description: 'Timed out waiting for ${proofCase.label} dark token',
      );
      final darkTerminal = _terminalFromView(tester);
      final darkContrast = _minimumTokenContrast(
        darkTerminal,
        monkey_themes.TerminalThemes.defaultDarkTheme,
        darkToken,
      );
      final darkSurface = _composerSurfaceForToken(
        darkTerminal,
        monkey_themes.TerminalThemes.defaultDarkTheme,
        darkToken,
      );
      await binding.takeScreenshot('${proofCase.id}-dark-readable');
      expect(darkContrast, greaterThanOrEqualTo(3.0));
      expect(darkSurface.sampledCells, greaterThan(darkToken.length));
      expect(darkSurface.background.computeLuminance(), lessThan(0.45));

      await _switchThemeMode(tester, terminal.container, ThemeMode.light);
      final lightToken = '${proofCase.tokenPrefix}l$suffix';
      _terminalFromView(tester).textInput(lightToken);
      await _waitForTerminalText(
        tester,
        () => _terminalFromView(tester),
        lightToken,
        description: 'Timed out waiting for ${proofCase.label} light token',
      );
      final lightTerminal = _terminalFromView(tester);
      final lightContrast = _minimumTokenContrast(
        lightTerminal,
        monkey_themes.TerminalThemes.defaultLightTheme,
        lightToken,
      );
      final lightSurface = _composerSurfaceForToken(
        lightTerminal,
        monkey_themes.TerminalThemes.defaultLightTheme,
        lightToken,
      );
      await binding.takeScreenshot('${proofCase.id}-light-readable');
      expect(lightContrast, greaterThanOrEqualTo(3.0));
      expect(lightSurface.sampledCells, greaterThan(lightToken.length));
      expect(lightSurface.background.computeLuminance(), greaterThan(0.55));

      debugPrint(
        '${proofCase.id} contrast dark=$darkContrast light=$lightContrast '
        'surface dark=${darkSurface.background} '
        'light=${lightSurface.background}',
      );
    });
  }
}

class _ProofCase {
  const _ProofCase({
    required this.id,
    required this.label,
    required this.expectedText,
    required this.tokenPrefix,
    this.startupCommand,
    this.tmuxSessionName,
  });

  final String id;
  final String label;
  final String expectedText;
  final String tokenPrefix;
  final String? startupCommand;
  final String? tmuxSessionName;
}

Future<({ProviderContainer container})> _pumpProofTerminal(
  WidgetTester tester,
  _ProofCase proofCase,
) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final encryptionService = SecretEncryptionService.forTesting();
  final hostRepository = HostRepository(db, encryptionService);
  final keyRepository = KeyRepository(db, encryptionService);

  await db
      .into(db.settings)
      .insertOnConflictUpdate(
        SettingsCompanion.insert(
          key: SettingKeys.defaultTerminalThemeLight,
          value: 'clean-white',
        ),
      );
  await db
      .into(db.settings)
      .insertOnConflictUpdate(
        SettingsCompanion.insert(
          key: SettingKeys.defaultTerminalThemeDark,
          value: 'ocean-dark',
        ),
      );

  final keyId = await keyRepository.insert(
    SshKeysCompanion.insert(
      name: '${proofCase.label} proof key',
      keyType: 'ed25519',
      publicKey: utf8.decode(base64Decode(_sshPublicKeyBase64)),
      privateKey: utf8.decode(base64Decode(_sshPrivateKeyBase64)),
      passphrase: const Value(null),
      fingerprint: Value('${proofCase.id}-proof'),
    ),
  );

  final hostId = await hostRepository.insert(
    HostsCompanion.insert(
      label: '${proofCase.label} proof',
      hostname: _deviceReachableHost,
      port: const Value(_sshPort),
      username: _sshUser,
      keyId: Value(keyId),
      password: const Value(null),
      autoConnectRequiresConfirmation: const Value(false),
      terminalThemeLightId: const Value('clean-white'),
      terminalThemeDarkId: const Value('ocean-dark'),
      tmuxSessionName: Value(proofCase.tmuxSessionName),
      tmuxWorkingDirectory: const Value(_workdir),
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
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    container.dispose();
    await db.close();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, child) {
          final themeMode = ref.watch(themeModeNotifierProvider);
          return MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: themeMode,
            home: child,
          );
        },
        child: TerminalScreen(hostId: hostId),
      ),
    ),
  );
  await container
      .read(themeModeNotifierProvider.notifier)
      .setThemeMode(ThemeMode.light);
  await tester.pumpAndSettle();

  await _pumpUntilConnected(tester);
  await _pumpUntilFound(tester, find.byType(MonkeyTerminalView));
  return (container: container);
}

Future<void> _pumpUntilConnected(WidgetTester tester) async {
  await _pumpUntil(
    tester,
    () => find.text('Connecting...').evaluate().isEmpty,
    description: 'SSH connection to proof host',
    timeout: const Duration(seconds: 60),
  );
  expect(find.textContaining('Failed to start shell'), findsNothing);
  expect(find.textContaining('Connection failed'), findsNothing);
}

Future<void> _switchThemeMode(
  WidgetTester tester,
  ProviderContainer container,
  ThemeMode mode,
) async {
  await container.read(themeModeNotifierProvider.notifier).setThemeMode(mode);
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
  Terminal Function() terminal,
  String expected, {
  required String description,
  Duration timeout = const Duration(seconds: 20),
}) async {
  await _pumpUntil(
    tester,
    () => _terminalBufferText(terminal()).contains(expected),
    description: '$description\n${_terminalBufferText(terminal())}',
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
  final palette = _buildTerminalPalette(xtermTheme);
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
      final column = startColumn + offset;
      if (row == terminal.buffer.absoluteCursorY &&
          column == terminal.buffer.cursorX) {
        continue;
      }
      line.getCellData(column, cell);
      final colors = _effectiveCellColors(cell, xtermTheme, palette);
      minimum = math.min(
        minimum,
        _contrastRatio(colors.foreground, colors.background),
      );
    }
    if (minimum == double.infinity) {
      continue;
    }
    return minimum;
  }

  fail('Could not find token "$token" in terminal buffer.');
}

({Color background, int sampledCells}) _composerSurfaceForToken(
  Terminal terminal,
  TerminalThemeData theme,
  String token,
) {
  final xtermTheme = theme.toXtermTheme();
  final palette = _buildTerminalPalette(xtermTheme);
  final cell = CellData.empty();

  for (var row = 0; row < terminal.buffer.lines.length; row += 1) {
    final line = terminal.buffer.lines[row];
    final text = line.getText(0, terminal.buffer.viewWidth);
    final startColumn = text.indexOf(token);
    if (startColumn == -1) {
      continue;
    }

    line.getCellData(startColumn, cell);
    final tokenSurfaceColor = _effectiveBackgroundCellColor(cell);
    final background = _effectiveCellColors(
      cell,
      xtermTheme,
      palette,
    ).background;
    var sampledCells = 0;

    for (var column = 0; column < terminal.buffer.viewWidth; column += 1) {
      line.getCellData(column, cell);
      if (_effectiveBackgroundCellColor(cell) == tokenSurfaceColor) {
        sampledCells += 1;
      }
    }

    return (background: background, sampledCells: sampledCells);
  }

  fail('Could not find token "$token" in terminal buffer.');
}

int _effectiveBackgroundCellColor(CellData cell) =>
    (cell.flags & CellFlags.inverse) == 0 ? cell.background : cell.foreground;

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
    foreground = resolveMonkeyTerminalFaintForegroundColor(
      foreground: foreground,
      background: background,
    );
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

List<Color> _buildTerminalPalette(TerminalTheme xtermTheme) =>
    List<Color>.generate(
      256,
      (index) => resolveMonkeyTerminalPaletteColor(xtermTheme, index),
      growable: false,
    );

double _contrastRatio(Color a, Color b) {
  final luminanceA = a.computeLuminance();
  final luminanceB = b.computeLuminance();
  final brightest = math.max(luminanceA, luminanceB);
  final darkest = math.min(luminanceA, luminanceB);
  return (brightest + 0.05) / (darkest + 0.05);
}
