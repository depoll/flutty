// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/acp_provider.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/domain/services/acp_provider_service.dart';
import 'package:monkeyssh/domain/services/acp_session_manager.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/widgets/agents_panel.dart';

import '../support/fake_acp_session_manager.dart';

Widget _wrap(FakeAcpSessionManager manager) => ProviderScope(
  overrides: [
    acpSessionManagerProvider.overrideWithValue(manager),
    allHostsProvider.overrideWith((ref) => Stream.value(const <Host>[])),
    acpProvidersProvider.overrideWith(
      (ref) => Stream.value(<AcpProvider>[
        for (final builtin in acpBuiltinProviders)
          AcpBuiltinProviderView(builtin),
      ]),
    ),
  ],
  child: const MaterialApp(home: Scaffold(body: AgentsPanel())),
);

void main() {
  testWidgets('renders branded empty state and a New session action', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(FakeAcpSessionManager()));
    await tester.pumpAndSettle();

    expect(find.text('no agent sessions yet'), findsOneWidget);
    // Bottom-reachable New session action plus the empty-state primary.
    expect(find.widgetWithText(FilledButton, 'New session'), findsWidgets);
  });

  testWidgets('lists a live session with provider, status and cwd summary', (
    tester,
  ) async {
    final session = fakeAcpSession(title: 'Refactor auth');
    await tester.pumpWidget(_wrap(FakeAcpSessionManager(sessions: [session])));
    await tester.pumpAndSettle();

    expect(find.text('Refactor auth'), findsOneWidget);
    expect(find.textContaining('Copilot CLI'), findsOneWidget);
    expect(find.textContaining('…/project'), findsOneWidget);
    expect(find.textContaining('ready'), findsOneWidget);
  });

  testWidgets('shows a pending-permission indicator', (tester) async {
    final session = fakeAcpSession(
      pendingPermissions: [
        AcpPendingPermission(
          requestKey: 'r1',
          sessionId: 'session-1',
          toolCallId: 'tool-1',
          options: const [],
          requestedAt: DateTime(2026),
        ),
      ],
    );
    await tester.pumpWidget(_wrap(FakeAcpSessionManager(sessions: [session])));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.pending_actions), findsWidgets);
  });

  testWidgets('opens the new-session sheet from the bottom action', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(FakeAcpSessionManager()));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'New session').last);
    await tester.pumpAndSettle();

    expect(find.text('new agent session'), findsOneWidget);
  });
}
