import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

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
  label: 'Terminal selection test host',
  hostname: 'terminal.example.com',
  port: 22,
  username: 'root',
  isFavorite: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  autoConnectRequiresConfirmation: false,
  sortOrder: 0,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const SSHPtyConfig());
    registerFallbackValue(Uint8List(0));
  });

  testWidgets(
    'long press refreshes the native overlay from live terminal output',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final hostRepository = _MockHostRepository();
      final sshClient = _MockSshClient();
      final shellChannel = _MockShellChannel();
      final host = _buildHost(id: 1);
      final shellDoneCompleter = Completer<void>();
      final shellStdoutController = StreamController<Uint8List>.broadcast();
      addTearDown(shellStdoutController.close);

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

      final session = SshSession(
        connectionId: 7,
        hostId: host.id,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'terminal.example.com',
          port: 22,
          username: 'root',
        ),
      )..getOrCreateTerminal();

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          hostRepositoryProvider.overrideWithValue(hostRepository),
          sharedClipboardProvider.overrideWith((ref) async => false),
          activeSessionsProvider.overrideWith(
            () => _TestActiveSessionsNotifier(session),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
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

      session.terminal!.write('alpha');
      await tester.pumpAndSettle();

      await tester.longPressAt(cellCenter(const CellOffset(2, 0)));
      await tester.pumpAndSettle();

      final overlayField = find.byType(TextField);
      expect(overlayField, findsOneWidget);
      var overlayController = tester.widget<TextField>(overlayField).controller;
      expect(overlayController, isNotNull);
      expect(overlayController!.text, contains('alpha'));

      session.terminal!.write('\r\ncharlie');
      await tester.pumpAndSettle();
      expect(overlayController.text, isNot(contains('charlie')));

      await tester.longPressAt(cellCenter(const CellOffset(2, 1)));
      await tester.pumpAndSettle();

      overlayController = tester.widget<TextField>(overlayField).controller;
      expect(overlayController, isNotNull);
      expect(overlayController!.text, contains('charlie'));
      expect(overlayController.selection.isCollapsed, isFalse);
    },
    skip: defaultTargetPlatform != TargetPlatform.android,
  );
}
