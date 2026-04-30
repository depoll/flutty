// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

class _MockHostRepository extends Mock implements HostRepository {}

class _MockSshClient extends Mock implements SSHClient {}

class _MockShellChannel extends Mock implements SSHSession {}

class _MockMonetizationService extends Mock implements MonetizationService {}

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

Host _buildHost({required int id, required String tmuxSessionName}) => Host(
  id: id,
  label: 'Notification navigation validation',
  hostname: 'terminal.example.com',
  port: 22,
  username: 'root',
  tmuxSessionName: tmuxSessionName,
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const SSHPtyConfig());
    registerFallbackValue(<int>[]);
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(MonetizationFeature.autoConnectAutomation);
  });

  testWidgets(
    'notification tmux target selects the stable window ID on device',
    (tester) async {
      const tmuxSessionName = 'alerts';
      const stalePayloadWindowIndex = 2;
      const currentTargetWindowIndex = 3;
      const targetWindowId = '@9';
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final hostRepository = _MockHostRepository();
      final sshClient = _MockSshClient();
      final shellChannel = _MockShellChannel();
      final tmuxService = _MockTmuxService();
      final monetizationService = _MockMonetizationService();
      final host = _buildHost(id: 1, tmuxSessionName: tmuxSessionName);
      final shellDoneCompleter = Completer<void>();
      final shellStdoutController = StreamController<Uint8List>.broadcast();

      addTearDown(() async {
        await shellStdoutController.close();
        await db.close();
      });

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
      when(
        () => monetizationService.currentState,
      ).thenReturn(_proMonetizationState);
      when(
        () => monetizationService.states,
      ).thenAnswer((_) => Stream.value(_proMonetizationState));
      when(
        monetizationService.initialize,
      ).thenAnswer((_) => Future<void>.value());
      when(
        () => monetizationService.canUseFeature(any()),
      ).thenAnswer((_) async => true);
      when(
        () => tmuxService.hasSessionOrThrow(session, tmuxSessionName),
      ).thenAnswer((_) async => true);
      when(() => tmuxService.listWindows(session, tmuxSessionName)).thenAnswer(
        (_) async => const <TmuxWindow>[
          TmuxWindow(index: 1, id: '@8', name: 'shell', isActive: true),
          TmuxWindow(
            index: currentTargetWindowIndex,
            id: targetWindowId,
            name: 'agent',
            isActive: false,
          ),
        ],
      );
      when(
        () => tmuxService.selectWindow(
          session,
          tmuxSessionName,
          currentTargetWindowIndex,
          windowId: targetWindowId,
        ),
      ).thenAnswer((_) async {});
      when(
        () => tmuxService.hasForegroundClient(session, tmuxSessionName),
      ).thenAnswer((_) async => true);
      when(
        () => tmuxService.watchWindowChanges(session, tmuxSessionName),
      ).thenAnswer((_) => const Stream<TmuxWindowChangeEvent>.empty());
      when(
        () => tmuxService.prefetchInstalledAgentTools(session),
      ).thenAnswer((_) async {});
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
              initialTmuxWindowIndex: stalePayloadWindowIndex,
              initialTmuxWindowId: targetWindowId,
              initialTmuxWindowRequiresVisibleSession: true,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      verify(
        () => tmuxService.selectWindow(
          session,
          tmuxSessionName,
          currentTargetWindowIndex,
          windowId: targetWindowId,
        ),
      ).called(1);
    },
  );
}
