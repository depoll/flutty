// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/host_cli_launch_preferences.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/host_cli_launch_preferences_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';
import 'package:xterm/xterm.dart';

const _deleteDetectionMarker = '\u200B\u200B';

class _MockHostRepository extends Mock implements HostRepository {}

class _MockSshClient extends Mock implements SSHClient {}

class _MockShellChannel extends Mock implements SSHSession {}

class _MockMonetizationService extends Mock implements MonetizationService {}

class _MockSftpClient extends Mock implements SftpClient {}

class _MockTmuxService extends Mock implements TmuxService {}

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  _TestActiveSessionsNotifier(this.session);

  final SshSession session;

  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{
    session.connectionId: SshConnectionState.connected,
  };

  @override
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) => null;

  @override
  List<int> getConnectionsForHost(int hostId) =>
      hostId == session.hostId ? <int>[session.connectionId] : const <int>[];

  @override
  ActiveConnection? getActiveConnection(int connectionId) => null;

  @override
  SshSession? getSession(int connectionId) =>
      connectionId == session.connectionId ? session : null;

  @override
  Future<void> syncBackgroundStatus() async {}
}

Host _buildHost({required int id, String? autoConnectCommand}) => Host(
  id: id,
  label: 'Terminal test host',
  hostname: 'terminal.example.com',
  port: 22,
  username: 'root',
  autoConnectCommand: autoConnectCommand,
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoConnectRequiresConfirmation: false,
  sortOrder: 0,
);

const _proMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

TextEditingValue _editingValue(String text, {required int selectionOffset}) =>
    TextEditingValue(
      text: '$_deleteDetectionMarker$text',
      selection: TextSelection.collapsed(
        offset: _deleteDetectionMarker.length + selectionOffset,
      ),
    );

void main() {
  setUpAll(() {
    registerFallbackValue(const SSHPtyConfig());
    registerFallbackValue(<int>[]);
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(MonetizationFeature.autoConnectAutomation);
  });

  group('TerminalScreen mobile IME wiring', () {
    late AppDatabase db;
    late _MockHostRepository hostRepository;
    late _MockSshClient sshClient;
    late _MockShellChannel shellChannel;
    late _MockMonetizationService monetizationService;
    late SshSession session;
    late Host host;
    late Completer<void> shellDoneCompleter;
    late StreamController<Uint8List> shellStdoutController;
    late List<List<int>> shellWrites;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      hostRepository = _MockHostRepository();
      sshClient = _MockSshClient();
      shellChannel = _MockShellChannel();
      monetizationService = _MockMonetizationService();
      host = _buildHost(id: 1);
      shellDoneCompleter = Completer<void>();
      shellStdoutController = StreamController<Uint8List>.broadcast();
      shellWrites = <List<int>>[];

      when(
        () => monetizationService.currentState,
      ).thenReturn(_proMonetizationState);
      when(
        () => monetizationService.states,
      ).thenAnswer((_) => Stream.value(_proMonetizationState));
      when(() => monetizationService.initialize()).thenAnswer((_) async {});
      when(
        () => monetizationService.canUseFeature(any()),
      ).thenAnswer((_) async => true);

      when(() => hostRepository.getById(host.id)).thenAnswer((_) async => host);
      when(
        () => sshClient.shell(pty: any(named: 'pty')),
      ).thenAnswer((_) async => shellChannel);
      when(
        () => shellChannel.stdout,
      ).thenAnswer((_) => shellStdoutController.stream);
      when(
        () => shellChannel.stderr,
      ).thenAnswer((_) => const Stream<Uint8List>.empty());
      when(
        () => shellChannel.done,
      ).thenAnswer((_) => shellDoneCompleter.future);
      when(() => shellChannel.write(any())).thenAnswer((invocation) {
        final value = invocation.positionalArguments.single;
        if (value is List<int>) {
          shellWrites.add(List<int>.from(value));
        }
      });

      session = SshSession(
        connectionId: 7,
        hostId: host.id,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'terminal.example.com',
          port: 22,
          username: 'root',
        ),
      )..getOrCreateTerminal();
    });

    tearDown(() async {
      await shellStdoutController.close();
      await db.close();
    });

    Future<void> pumpScreen(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            monetizationServiceProvider.overrideWithValue(monetizationService),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_proMonetizationState),
            ),
            sharedClipboardProvider.overrideWith((ref) async => false),
            activeSessionsProvider.overrideWith(
              () => _TestActiveSessionsNotifier(session),
            ),
          ],
          child: MaterialApp(
            home: TerminalScreen(
              hostId: host.id,
              connectionId: session.connectionId,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
    }

    Future<void> pumpTmuxScreen(
      WidgetTester tester,
      _MockTmuxService tmuxService,
    ) async {
      const tmuxSessionName = 'work';
      const windows = <TmuxWindow>[
        TmuxWindow(index: 0, name: 'shell', isActive: true),
        TmuxWindow(index: 1, name: 'agent', isActive: false),
      ];

      when(
        () => tmuxService.hasSession(session, tmuxSessionName),
      ).thenAnswer((_) async => true);
      when(
        () => tmuxService.listWindows(session, tmuxSessionName),
      ).thenAnswer((_) async => windows);
      when(
        () => tmuxService.watchWindowChanges(session, tmuxSessionName),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(
        () => tmuxService.detectInstalledAgentTools(session),
      ).thenAnswer((_) async => const <AgentLaunchTool>{});

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            hostRepositoryProvider.overrideWithValue(hostRepository),
            monetizationServiceProvider.overrideWithValue(monetizationService),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_proMonetizationState),
            ),
            sharedClipboardProvider.overrideWith((ref) async => false),
            activeSessionsProvider.overrideWith(
              () => _TestActiveSessionsNotifier(session),
            ),
            tmuxServiceProvider.overrideWithValue(tmuxService),
          ],
          child: MaterialApp(
            home: TerminalScreen(
              hostId: host.id,
              connectionId: session.connectionId,
              initialTmuxSessionName: tmuxSessionName,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets(
      'initial tmux target selects the alerted window on the source connection',
      (tester) async {
        final tmuxService = _MockTmuxService();
        const tmuxSessionName = 'alerts';
        const targetWindowIndex = 3;
        final windows = <TmuxWindow>[
          const TmuxWindow(index: 1, name: 'shell', isActive: true),
          const TmuxWindow(index: 3, name: 'agent', isActive: false),
        ];
        when(
          () => tmuxService.hasSession(session, tmuxSessionName),
        ).thenAnswer((_) async => true);
        when(
          () => tmuxService.listWindows(session, tmuxSessionName),
        ).thenAnswer((_) async => windows);
        when(
          () => tmuxService.selectWindow(
            session,
            tmuxSessionName,
            targetWindowIndex,
          ),
        ).thenAnswer((_) async {});
        when(
          () => tmuxService.hasForegroundClient(session, tmuxSessionName),
        ).thenAnswer((_) async => true);
        when(
          () => tmuxService.watchWindowChanges(session, tmuxSessionName),
        ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              hostRepositoryProvider.overrideWithValue(hostRepository),
              monetizationServiceProvider.overrideWithValue(
                monetizationService,
              ),
              monetizationStateProvider.overrideWith(
                (ref) => Stream.value(_proMonetizationState),
              ),
              sharedClipboardProvider.overrideWith((ref) async => false),
              activeSessionsProvider.overrideWith(
                () => _TestActiveSessionsNotifier(session),
              ),
              tmuxServiceProvider.overrideWithValue(tmuxService),
            ],
            child: MaterialApp(
              home: TerminalScreen(
                hostId: host.id,
                connectionId: session.connectionId,
                initialTmuxSessionName: tmuxSessionName,
                initialTmuxWindowIndex: targetWindowIndex,
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        verify(
          () => tmuxService.selectWindow(
            session,
            tmuxSessionName,
            targetWindowIndex,
          ),
        ).called(1);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'touching the terminal dismisses the expanded tmux bar',
      (tester) async {
        final tmuxService = _MockTmuxService();
        await pumpTmuxScreen(tester, tmuxService);

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        final dismissRegion = find.byKey(
          const ValueKey('tmux-terminal-dismiss-region'),
        );
        expect(dismissRegion, findsOneWidget);

        await tester.tapAt(const Offset(20, 120));
        await tester.pump();

        expect(dismissRegion, findsNothing);
        expect(find.byType(TerminalScreen), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'Android back dismisses the expanded tmux bar before leaving the terminal',
      (tester) async {
        final tmuxService = _MockTmuxService();
        await pumpTmuxScreen(tester, tmuxService);

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        final dismissRegion = find.byKey(
          const ValueKey('tmux-terminal-dismiss-region'),
        );
        expect(dismissRegion, findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pump();

        expect(dismissRegion, findsNothing);
        expect(find.byType(TerminalScreen), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'hiding the expanded tmux bar restores normal back handling',
      (tester) async {
        final tmuxService = _MockTmuxService();
        await pumpTmuxScreen(tester, tmuxService);

        await tester.tap(find.byKey(const ValueKey('tmux-handle-bar')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        final popScope = find.byWidgetPredicate((widget) => widget is PopScope);
        final dismissRegion = find.byKey(
          const ValueKey('tmux-terminal-dismiss-region'),
        );
        expect(dismissRegion, findsOneWidget);
        expect(tester.widget<PopScope<Object?>>(popScope).canPop, isFalse);

        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hide tmux Bar'));
        await tester.pumpAndSettle();

        expect(dismissRegion, findsNothing);
        expect(tester.widget<PopScope<Object?>>(popScope).canPop, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'auto-connect rebuilds agent launch commands from the saved preset and host yolo preference',
      (tester) async {
        final settingsService = SettingsService(db);
        final presetService = AgentLaunchPresetService(settingsService);
        final cliLaunchPreferencesService = HostCliLaunchPreferencesService(
          settingsService,
        );
        session = SshSession(
          connectionId: 7,
          hostId: host.id,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'terminal.example.com',
            port: 22,
            username: 'root',
          ),
        );
        host = _buildHost(
          id: host.id,
          autoConnectCommand: 'codex --approval-mode never',
        );
        await presetService.setPresetForHost(
          host.id,
          const AgentLaunchPreset(tool: AgentLaunchTool.codex),
        );
        await cliLaunchPreferencesService.setPreferencesForHost(
          host.id,
          const HostCliLaunchPreferences(startInYoloMode: true),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              databaseProvider.overrideWithValue(db),
              settingsServiceProvider.overrideWithValue(settingsService),
              hostRepositoryProvider.overrideWithValue(hostRepository),
              monetizationServiceProvider.overrideWithValue(
                monetizationService,
              ),
              monetizationStateProvider.overrideWith(
                (ref) => Stream.value(_proMonetizationState),
              ),
              sharedClipboardProvider.overrideWith((ref) async => false),
              activeSessionsProvider.overrideWith(
                () => _TestActiveSessionsNotifier(session),
              ),
            ],
            child: MaterialApp(
              home: TerminalScreen(
                hostId: host.id,
                connectionId: session.connectionId,
              ),
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final writtenShellText = utf8.decode(
          shellWrites.expand((chunk) => chunk).toList(growable: false),
        );
        expect(writtenShellText, contains('codex --yolo'));
        expect(writtenShellText, isNot(contains('--approval-mode never')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'toolbar navigation keys clear the screen IME buffer',
      (tester) async {
        await pumpScreen(tester);

        expect(find.byType(TerminalTextInputHandler), findsOneWidget);
        tester.testTextInput.updateEditingValue(
          _editingValue('hello', selectionOffset: 5),
        );
        await tester.pump();

        await tester.tap(find.byTooltip('Left'));
        await tester.pump();

        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'toolbar Ctrl state flows into the screen IME handler',
      (tester) async {
        await pumpScreen(tester);

        var handler = tester.widget<TerminalTextInputHandler>(
          find.byType(TerminalTextInputHandler),
        );
        expect(handler.hasActiveToolbarModifier?.call(), isFalse);

        await tester.tap(find.byTooltip('Ctrl'));
        await tester.pump();

        handler = tester.widget<TerminalTextInputHandler>(
          find.byType(TerminalTextInputHandler),
        );
        expect(handler.hasActiveToolbarModifier?.call(), isTrue);

        tester.testTextInput.updateEditingValue(
          _editingValue('b', selectionOffset: 1),
        );
        await tester.pump();
        final client =
            tester.state(find.byType(TerminalTextInputHandler))
                as TextInputClient;
        expect(
          client.currentTextEditingValue,
          const TextEditingValue(
            text: _deleteDetectionMarker,
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'prompt-like shell output does not reconnect the IME input client before keyboard input',
      (tester) async {
        await pumpScreen(tester);

        tester.testTextInput.log.clear();
        shellStdoutController.add(Uint8List.fromList(utf8.encode('> ')));
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setClient',
          ),
          isEmpty,
        );
        await tester.pump(const Duration(milliseconds: 200));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'prompt-like shell output reconnects the IME input client after keyboard input',
      (tester) async {
        await pumpScreen(tester);

        tester.testTextInput.updateEditingValue(
          _editingValue('ls', selectionOffset: 2),
        );
        await tester.pump();

        await tester.testTextInput.receiveAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.log.clear();
        shellStdoutController.add(Uint8List.fromList(utf8.encode('> ')));
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          hasLength(greaterThanOrEqualTo(1)),
        );
        await tester.pump(const Duration(milliseconds: 200));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'ANSI-styled prompt-like shell output reconnects the IME input client after keyboard input',
      (tester) async {
        await pumpScreen(tester);

        tester.testTextInput.updateEditingValue(
          _editingValue('ls', selectionOffset: 2),
        );
        await tester.pump();

        await tester.testTextInput.receiveAction(TextInputAction.newline);
        await tester.pump();

        tester.testTextInput.log.clear();
        shellStdoutController.add(
          Uint8List.fromList(utf8.encode('\u001b[38;5;39m>\u001b[0m ')),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          hasLength(greaterThanOrEqualTo(1)),
        );
        await tester.pump(const Duration(milliseconds: 200));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'running shell commands bypass keyboard paste review',
      (tester) async {
        await pumpScreen(tester);

        session.terminal!.write('\u001b]133;C\u0007');
        await tester.pump();

        expect(session.shellStatus, TerminalShellStatus.runningCommand);

        shellWrites.clear();
        const suspiciousText = 'echo ready; rm -rf /';
        tester.testTextInput.updateEditingValue(
          _editingValue(suspiciousText, selectionOffset: suspiciousText.length),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('Review keyboard paste'), findsNothing);
        expect(shellWrites.map(utf8.decode).join(), suspiciousText);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'non-prompt shell output does not reconnect the IME input client',
      (tester) async {
        await pumpScreen(tester);

        tester.testTextInput.log.clear();
        shellStdoutController.add(
          Uint8List.fromList(utf8.encode('running task...\ncompleted 1/3')),
        );
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setClient',
          ),
          isEmpty,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'shell stdout errors are handled without breaking the screen',
      (tester) async {
        await pumpScreen(tester);

        shellStdoutController.addError(StateError('stdout failed'));
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.byType(TerminalTextInputHandler), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      'overlay long press reselects from the touch-down snapshot while output streams during the hold',
      (tester) async {
        await pumpScreen(tester);

        session.terminal!.write('alpha');
        await tester.pumpAndSettle();

        Offset cellCenter(CellOffset offset) {
          final terminalViewState = tester.state<MonkeyTerminalViewState>(
            find.byType(MonkeyTerminalView),
          );
          final renderTerminal = terminalViewState.renderTerminal;
          return renderTerminal.localToGlobal(
            renderTerminal.getOffset(offset) +
                renderTerminal.cellSize.center(Offset.zero),
          );
        }

        await tester.longPressAt(cellCenter(const CellOffset(2, 0)));
        await tester.pumpAndSettle();

        final overlayField = find.byType(TextField);
        expect(overlayField, findsOneWidget);
        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        expect(terminalView.controller, isNotNull);
        expect(terminalView.controller!.selection, isNull);
        var overlayController = tester
            .widget<TextField>(overlayField)
            .controller;
        expect(overlayController, isNotNull);
        expect(overlayController!.selection.isCollapsed, isFalse);
        expect(overlayController.text, contains('alpha'));

        session.terminal!.write('\r\ncharlie');
        await tester.pumpAndSettle();
        expect(overlayController.text, isNot(contains('charlie')));

        var streamIndex = 0;
        final streamTimer = Timer.periodic(const Duration(milliseconds: 16), (
          _,
        ) {
          session.terminal!.write('\r\nstream $streamIndex');
          streamIndex += 1;
        });
        addTearDown(streamTimer.cancel);

        final gesture = await tester.startGesture(
          cellCenter(const CellOffset(2, 1)),
        );
        await tester.pump(const Duration(milliseconds: 650));
        await tester.pumpAndSettle();
        await gesture.up();
        await tester.pumpAndSettle();

        streamTimer.cancel();

        expect(terminalView.controller!.selection, isNull);
        overlayController = tester.widget<TextField>(overlayField).controller;
        expect(overlayController, isNotNull);
        expect(overlayController!.selection.isCollapsed, isFalse);
        expect(
          overlayController.selection.textInside(overlayController.text),
          'charlie',
        );
        expect(overlayController.text, isNot(contains('stream')));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'overlay scroll stays fixed while a native selection is active',
      (tester) async {
        await pumpScreen(tester);

        final initialLines = List<String>.generate(
          40,
          (index) => index == 39 ? 'alpha' : 'line $index',
        ).join('\r\n');
        session.terminal!.write(initialLines);
        await tester.pumpAndSettle();

        Offset? tokenCenter(String token) {
          final terminalViewState = tester.state<MonkeyTerminalViewState>(
            find.byType(MonkeyTerminalView),
          );
          final renderTerminal = terminalViewState.renderTerminal;
          final firstVisibleRow =
              (session.terminal!.buffer.lines.length -
                      session.terminal!.viewHeight)
                  .clamp(0, session.terminal!.buffer.lines.length - 1);

          for (
            var row = firstVisibleRow;
            row < session.terminal!.buffer.lines.length;
            row += 1
          ) {
            final lineText = trimTerminalLinePadding(
              session.terminal!.buffer.lines[row].getText(
                0,
                session.terminal!.buffer.viewWidth,
              ),
            );
            final startColumn = lineText.indexOf(token);
            if (startColumn == -1) {
              continue;
            }

            final tapColumn = startColumn + (token.length ~/ 2);
            final cellOffset = CellOffset(tapColumn, row);
            return renderTerminal.localToGlobal(
              renderTerminal.getOffset(cellOffset) +
                  renderTerminal.cellSize.center(Offset.zero),
            );
          }

          return null;
        }

        final alphaCenter = tokenCenter('alpha');
        expect(alphaCenter, isNotNull);

        await tester.longPressAt(alphaCenter!);
        await tester.pumpAndSettle();

        final overlayField = find.byType(TextField);
        expect(overlayField, findsOneWidget);
        final overlayTextField = tester.widget<TextField>(overlayField);
        final overlayController = overlayTextField.controller;
        final overlayScrollController = overlayTextField.scrollController;
        expect(overlayController, isNotNull);
        expect(overlayController!.selection.isCollapsed, isFalse);
        expect(overlayScrollController, isNotNull);
        expect(overlayScrollController!.hasClients, isTrue);

        final initialOverlayOffset = overlayScrollController.offset;
        expect(initialOverlayOffset, greaterThan(0));

        session.terminal!.write('\r\ncharlie');
        await tester.pumpAndSettle();

        expect(overlayController.text, isNot(contains('charlie')));
        expect(overlayScrollController.offset, initialOverlayOffset);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'link long press keeps the touched word selected while output streams during the hold',
      (tester) async {
        await pumpScreen(tester);

        session.terminal!.write('visit https://alpha.test');
        await tester.pumpAndSettle();

        ({CellOffset cellOffset, Offset center})? tokenHit(String token) {
          final terminalViewState = tester.state<MonkeyTerminalViewState>(
            find.byType(MonkeyTerminalView),
          );
          final renderTerminal = terminalViewState.renderTerminal;
          final firstVisibleRow =
              (session.terminal!.buffer.lines.length -
                      session.terminal!.viewHeight)
                  .clamp(0, session.terminal!.buffer.lines.length - 1);

          for (
            var row = firstVisibleRow;
            row < session.terminal!.buffer.lines.length;
            row += 1
          ) {
            final lineText = trimTerminalLinePadding(
              session.terminal!.buffer.lines[row].getText(
                0,
                session.terminal!.buffer.viewWidth,
              ),
            );
            final startColumn = lineText.indexOf(token);
            if (startColumn == -1) {
              continue;
            }

            final tapColumn = startColumn + (token.length ~/ 2);
            final cellOffset = CellOffset(tapColumn, row);
            return (
              cellOffset: cellOffset,
              center: renderTerminal.localToGlobal(
                renderTerminal.getOffset(cellOffset) +
                    renderTerminal.cellSize.center(Offset.zero),
              ),
            );
          }

          return null;
        }

        final hit = tokenHit('alpha');
        expect(hit, isNotNull);
        final wordRange = session.terminal!.buffer.getWordBoundary(
          hit!.cellOffset,
        );
        expect(wordRange, isNotNull);
        final expectedWord = session.terminal!.buffer.lines[wordRange!.begin.y]
            .getText(wordRange.begin.x, wordRange.end.x);

        var streamIndex = 0;
        final streamTimer = Timer.periodic(const Duration(milliseconds: 16), (
          _,
        ) {
          session.terminal!.write('\r\nstream $streamIndex');
          streamIndex += 1;
        });
        addTearDown(streamTimer.cancel);

        final gesture = await tester.startGesture(hit.center);
        await tester.pump(const Duration(milliseconds: 650));
        await tester.pumpAndSettle();
        await gesture.up();
        await tester.pumpAndSettle();

        streamTimer.cancel();

        final overlayField = find.byType(TextField);
        expect(overlayField, findsOneWidget);
        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        expect(terminalView.controller, isNotNull);
        expect(terminalView.controller!.selection, isNull);
        final overlayController = tester
            .widget<TextField>(overlayField)
            .controller;
        expect(overlayController, isNotNull);
        expect(overlayController!.selection.isCollapsed, isFalse);
        expect(
          overlayController.selection.textInside(overlayController.text),
          expectedWord,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'prompt path underline tracks scroll without dropping a frame',
      (tester) async {
        await pumpScreen(tester);

        final output = <String>[
          for (var index = 0; index < 80; index++) 'line $index',
          'metadata rows no longer get folded into the path',
          '~/Code/flutty [⇢main]',
        ].join('\r\n');
        session.terminal!.write(output);
        await tester.pumpAndSettle();

        final underlineFinder = find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> &&
              key.value.startsWith('terminal-path-underline:');
        });

        expect(underlineFinder, findsOneWidget);
        final initialTop = tester.getTopLeft(underlineFinder).dy;
        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        final scrollController = terminalView.scrollController;
        final lineHeight = tester
            .state<MonkeyTerminalViewState>(find.byType(MonkeyTerminalView))
            .renderTerminal
            .lineHeight;
        expect(scrollController, isNotNull);
        expect(scrollController!.position.maxScrollExtent, greaterThan(0));
        scrollController.jumpTo(
          (scrollController.offset - (lineHeight / 2)).clamp(
            0.0,
            scrollController.position.maxScrollExtent,
          ),
        );
        await tester.pump();

        expect(underlineFinder, findsOneWidget);
        expect(tester.getTopLeft(underlineFinder).dy, isNot(initialTop));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'verified relative paths gain an underline after verification completes',
      (tester) async {
        const relativePath = 'lib/presentation/screens/terminal_screen.dart';
        const workingDirectory = '/Users/tester/project';
        final sftp = _MockSftpClient();
        final statCompleter = Completer<SftpFileAttrs>();

        when(() => sshClient.sftp()).thenAnswer((_) async => sftp);
        when(
          () => sftp.stat('$workingDirectory/$relativePath'),
        ).thenAnswer((_) => statCompleter.future);

        await pumpScreen(tester);
        shellStdoutController.add(
          Uint8List.fromList(
            utf8.encode(
              '\u001b]7;file://remote.example.com$workingDirectory\u0007',
            ),
          ),
        );
        await tester.pumpAndSettle();

        session.terminal!.write('git add $relativePath');
        await tester.pump();

        final underlineFinder = find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> &&
              key.value.contains('terminal-path-underline:') &&
              key.value.contains(relativePath);
        });

        expect(underlineFinder, findsNothing);

        statCompleter.complete(
          SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
        );
        await tester.pumpAndSettle();

        expect(underlineFinder, findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets(
      'extra keys toggle uses distinct copy',
      (tester) async {
        await pumpScreen(tester);

        expect(find.byTooltip('Hide extra keys'), findsOneWidget);
        expect(find.byTooltip('Show system keyboard'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byTooltip('Hide extra keys'),
            matching: find.byKey(const ValueKey('extra-keys-toggle-active')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byTooltip('Hide extra keys'),
            matching: find.text('Fn'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byTooltip('Hide extra keys'),
            matching: find.byKey(const ValueKey('extra-keys-toggle-inactive')),
          ),
          findsNothing,
        );
        expect(find.byIcon(Icons.keyboard_alt_outlined), findsOneWidget);
        expect(find.byIcon(Icons.keyboard_outlined), findsNothing);

        await tester.tap(find.byTooltip('Hide extra keys'));
        await tester.pump();

        expect(find.byTooltip('Show extra keys'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byTooltip('Show extra keys'),
            matching: find.byKey(const ValueKey('extra-keys-toggle-inactive')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byTooltip('Show extra keys'),
            matching: find.text('Fn'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byTooltip('Show extra keys'),
            matching: find.byKey(const ValueKey('extra-keys-toggle-active')),
          ),
          findsNothing,
        );
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}
