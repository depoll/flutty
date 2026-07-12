// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/agent_chat_screen.dart';
import 'package:monkeyssh/presentation/widgets/acp_composer.dart';
import 'package:monkeyssh/presentation/widgets/acp_message_thread.dart';
import 'package:monkeyssh/presentation/widgets/acp_permission_surface.dart';

import '../support/fake_acp_session_manager.dart';

class _MockSshService extends Mock implements SshService {}

Widget _wrap(
  FakeAcpSessionManager manager, {
  Size size = const Size(390, 800),
}) {
  final ssh = _MockSshService();
  when(() => ssh.getSessionsForHost(any())).thenReturn(const <SshSession>[]);
  final key = fakeAcpKey();
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
}
