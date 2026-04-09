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
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/terminal_text_input_handler.dart';

const _deleteDetectionMarker = '\u200B\u200B';

class _MockHostRepository extends Mock implements HostRepository {}

class _MockSshClient extends Mock implements SSHClient {}

class _MockShellChannel extends Mock implements SSHSession {}

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

Host _buildHost({required int id}) => Host(
  id: id,
  label: 'Terminal test host',
  hostname: 'terminal.example.com',
  port: 22,
  username: 'root',
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoConnectRequiresConfirmation: false,
  sortOrder: 0,
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
  });

  group('TerminalScreen mobile IME wiring', () {
    late AppDatabase db;
    late _MockHostRepository hostRepository;
    late _MockSshClient sshClient;
    late _MockShellChannel shellChannel;
    late SshSession session;
    late Host host;
    late Completer<void> shellDoneCompleter;
    late StreamController<Uint8List> shellStdoutController;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      hostRepository = _MockHostRepository();
      sshClient = _MockSshClient();
      shellChannel = _MockShellChannel();
      host = _buildHost(id: 1);
      shellDoneCompleter = Completer<void>();
      shellStdoutController = StreamController<Uint8List>.broadcast();

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
      when(() => shellChannel.write(any())).thenReturn(null);

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
            (call) => call.method == 'TextInput.setClient',
          ),
          hasLength(1),
        );
        await tester.pump(const Duration(milliseconds: 200));
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
      'extra keys toggle uses distinct copy',
      (tester) async {
        await pumpScreen(tester);

        expect(find.byTooltip('Hide extra keys'), findsOneWidget);
        expect(find.byTooltip('Show system keyboard'), findsOneWidget);
        expect(find.byIcon(Icons.dialpad_rounded), findsOneWidget);
        expect(find.byIcon(Icons.dialpad_outlined), findsNothing);
        expect(find.byIcon(Icons.keyboard_alt_outlined), findsOneWidget);
        expect(find.byIcon(Icons.keyboard_outlined), findsNothing);

        await tester.tap(find.byTooltip('Hide extra keys'));
        await tester.pump();

        expect(find.byTooltip('Show extra keys'), findsOneWidget);
        expect(find.byIcon(Icons.dialpad_outlined), findsOneWidget);
        expect(find.byIcon(Icons.dialpad_rounded), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}
