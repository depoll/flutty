// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_recent_session.dart';
import 'package:monkeyssh/domain/models/acp_session_keys.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/services/acp_concurrency_policy.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/agent_chat_screen.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';
import 'package:monkeyssh/presentation/widgets/acp_message_thread.dart';
import 'package:monkeyssh/presentation/widgets/acp_permission_surface.dart';

import '../support/fake_acp_session_manager.dart';

class _MockSshService extends Mock implements SshService {}

class _MockSshSession extends Mock implements SshSession {}

class _FakeSftpClient extends Fake implements SftpClient {}

Widget _wrap(
  FakeAcpSessionManager manager, {
  Size size = const Size(390, 800),
  AcpSessionKey? routeKey,
  bool hasActiveSshSession = false,
}) {
  final ssh = _MockSshService();
  final key = routeKey ?? fakeAcpKey();
  final sshSession = _MockSshSession();
  when(() => sshSession.connectionId).thenReturn(7);
  when(() => sshSession.hostId).thenReturn(key.hostId);
  when(sshSession.sftp).thenAnswer((_) async => _FakeSftpClient());
  when(() => ssh.getSessionsForHost(any())).thenReturn(
    hasActiveSshSession ? <SshSession>[sshSession] : const <SshSession>[],
  );
  return ProviderScope(
    overrides: [
      acpSessionManagerProvider.overrideWithValue(manager),
      sshServiceProvider.overrideWithValue(ssh),
    ],
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: AgentChatScreen(
          hostId: key.hostId,
          providerId: key.providerId,
          bridgeId: key.bridgeId,
          acpSessionId: key.acpSessionId,
          attachmentActionsBuilder: (_, _) =>
              const AcpComposerAttachmentActions(),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders the live timeline and composer on mobile', (
    tester,
  ) async {
    final session = fakeAcpSession(
      timeline: fakeAcpTimeline('Hello from the agent'),
    );
    await tester.pumpWidget(_wrap(FakeAcpSessionManager(sessions: [session])));
    await tester.pumpAndSettle();

    expect(find.byType(AcpMessageThread), findsOneWidget);
    expect(find.textContaining('Hello from the agent'), findsOneWidget);
    expect(find.byType(AcpComposer), findsOneWidget);
    expect(find.byTooltip('Session settings'), findsOneWidget);
  });

  testWidgets('renders a persistent session rail on wide layouts', (
    tester,
  ) async {
    final session = fakeAcpSession();
    await tester.pumpWidget(
      _wrap(
        FakeAcpSessionManager(sessions: [session]),
        size: const Size(1100, 800),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('sessions'), findsOneWidget);
    expect(find.byType(AcpMessageThread), findsOneWidget);
  });

  testWidgets('adopts the replacement bridge key after resuming an expired '
      'bridge', (tester) async {
    final oldKey = fakeAcpKey(bridgeId: 'expired-bridge');
    final resumedKey = fakeAcpKey(bridgeId: 'replacement-bridge');
    final now = DateTime(2026);
    final resumedSession = fakeAcpSession(
      key: resumedKey,
      timeline: fakeAcpTimeline('Recovered session'),
    );
    final manager =
        FakeAcpSessionManager(
            recents: [
              AcpRecentSessionRef(
                hostId: oldKey.hostId,
                providerId: oldKey.providerId,
                bridgeId: oldKey.bridgeId,
                acpSessionId: oldKey.acpSessionId,
                cwd: '/repo',
                createdAt: now,
                lastActivityAt: now,
              ),
            ],
          )
          ..reconnectSessionResult = AcpSessionLaunchStarted(resumedKey)
          ..reconnectSessionState = resumedSession;

    await tester.pumpWidget(
      _wrap(manager, routeKey: oldKey, hasActiveSshSession: true),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Recovered session'), findsOneWidget);
    expect(find.byType(AcpComposer), findsOneWidget);
    expect(find.text('Reconnect'), findsNothing);
    expect(manager.selected, contains(resumedKey.value));
    expect(manager.selected, isNot(contains(oldKey.value)));
    expect(manager.reconnects, hasLength(1));
    expect(manager.reconnects.single.bridgeId, oldKey.bridgeId);
  });

  testWidgets('surfaces a pending permission and resolves with the exact '
      'option id', (tester) async {
    final manager = FakeAcpSessionManager(
      sessions: [
        fakeAcpSession(
          pendingPermissions: [
            AcpPendingPermission(
              requestKey: 'req-1',
              sessionId: 'session-1',
              toolCallId: 'tool-1',
              options: const [
                AcpPermissionOption(
                  id: 'allow-1',
                  name: 'Allow once',
                  kind: AcpPermissionOptionKind.allowOnce,
                ),
              ],
              requestedAt: DateTime(2026),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    expect(find.byType(AcpPermissionSurface), findsOneWidget);
    expect(find.text('Allow once'), findsOneWidget);

    await tester.tap(find.text('Allow once'));
    await tester.pumpAndSettle();

    expect(manager.permissionResponses, [('req-1', 'allow-1')]);
  });

  testWidgets('a failed fork surfaces a safe error snackbar', (tester) async {
    final manager =
        FakeAcpSessionManager(
            sessions: [fakeAcpSession(capabilities: fakeAcpForkCapabilities())],
          )
          ..forkResults.add(
            const AcpSessionLaunchFailed(
              null,
              AcpSessionError(
                kind: AcpSessionErrorKind.unknown,
                message: 'Fork could not start.',
              ),
            ),
          );
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fork session'));
    await tester.pumpAndSettle();

    expect(manager.forkCount, 1);
    expect(find.text('Fork could not start.'), findsOneWidget);
  });

  testWidgets('a blocked fork stops the blocking session and retries after '
      'stop-and-continue', (tester) async {
    final currentKey = fakeAcpKey();
    final blockingKey = fakeAcpKey(acpSessionId: 'blocking');
    final manager =
        FakeAcpSessionManager(
            sessions: [
              fakeAcpSession(
                key: currentKey,
                capabilities: fakeAcpForkCapabilities(),
              ),
              fakeAcpSession(key: blockingKey, title: 'Busy session'),
            ],
          )
          ..forkResults.addAll([
            AcpSessionLaunchBlocked(
              AcpConcurrencyRequiresChoice(
                blockingSessionKeys: [blockingKey.value],
              ),
            ),
            const AcpSessionLaunchFailed(
              null,
              AcpSessionError(
                kind: AcpSessionErrorKind.unknown,
                message: 'Retry failed.',
              ),
            ),
          ]);
    await tester.pumpWidget(_wrap(manager));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fork session'));
    await tester.pumpAndSettle();

    // The shared concurrency choice is presented.
    expect(find.text('Stop and continue free'), findsOneWidget);
    await tester.tap(find.text('Stop and continue free'));
    await tester.pumpAndSettle();

    // The blocking session was stopped and the fork was retried.
    expect(manager.stopped, contains(blockingKey.value));
    expect(manager.forkCount, 2);
    expect(find.text('Retry failed.'), findsOneWidget);
  });
}
