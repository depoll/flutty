// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/agent_runtime_info.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/agent_management_screen.dart';

class _MockAgentManagementService extends Mock
    implements AgentManagementService {}

class _MockSshSession extends Mock implements SshSession {}

void main() {
  late _MockAgentManagementService service;
  late _MockSshSession session;
  late List<AgentRuntimeInfo> runtimes;

  setUp(() {
    service = _MockAgentManagementService();
    session = _MockSshSession();
    runtimes = [
      AgentRuntimeInfo(
        definition: agentCliRuntimeDefinitions.first,
        status: AgentRuntimeStatus.updateAvailable,
        installedVersion: '1.0.0',
        latestVersion: '1.1.0',
        executablePath: '/opt/homebrew/bin/claude',
        detectionSource: 'Homebrew',
        managedByPackageManager: true,
      ),
      AgentRuntimeInfo(
        definition: agentCliRuntimeDefinitions[1],
        status: AgentRuntimeStatus.notInstalled,
        latestVersion: '1.0.0',
      ),
      AgentRuntimeInfo(
        definition: agentStandaloneAcpRuntimeDefinitions.first,
        status: AgentRuntimeStatus.installed,
        installedVersion: '1.0.0',
        executablePath: '/usr/local/bin/copilot',
        detectionSource: 'npm or PATH',
      ),
    ];
    when(() => service.refreshAll(session)).thenAnswer((_) async => runtimes);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AgentManagementScreen(session: session, service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders CLI and ACP status with source paths', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Agent management'), findsOneWidget);
    expect(find.text('agent CLIs'), findsOneWidget);
    expect(find.text('ACP adapters'), findsOneWidget);
    expect(find.text('Update available v1.0.0 -> v1.1.0'), findsOneWidget);
    expect(find.text('Homebrew · /opt/homebrew/bin/claude'), findsOneWidget);
    expect(find.text('Not installed · latest v1.0.0'), findsOneWidget);
    expect(find.text('Installed v1.0.0'), findsOneWidget);
  });

  testWidgets('pull-to-refresh re-probes all runtimes', (tester) async {
    await pumpScreen(tester);
    clearInteractions(service);

    await tester.drag(
      find.byKey(const ValueKey('agent-management-list')),
      const Offset(0, 320),
    );
    await tester.pumpAndSettle();

    verify(() => service.refreshAll(session)).called(1);
  });

  testWidgets('header refresh re-probes all runtimes', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('agent-management-refresh')));
    await tester.pumpAndSettle();

    verify(() => service.refreshAll(session)).called(2);
  });

  testWidgets(
    'installed CLI without an available update has no Update action',
    (tester) async {
      runtimes[0] = AgentRuntimeInfo(
        definition: agentCliRuntimeDefinitions.first,
        status: AgentRuntimeStatus.installed,
        executablePath: '/usr/local/bin/claude',
        detectionSource: 'PATH',
        managedByPackageManager: true,
      );
      await pumpScreen(tester);

      expect(find.text('Check & update'), findsNothing);
      expect(
        find.byKey(const ValueKey('agent-action-cli:claude')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-recheck-cli:claude')),
        findsOneWidget,
      );
    },
  );

  testWidgets('Update all runs every confirmed update', (tester) async {
    final second = AgentRuntimeInfo(
      definition: agentCliRuntimeDefinitions[1],
      status: AgentRuntimeStatus.updateAvailable,
      installedVersion: '2.0.0',
      latestVersion: '2.1.0',
      executablePath: '/usr/local/bin/copilot',
      detectionSource: 'npm global',
      managedByPackageManager: true,
    );
    runtimes[1] = second;
    for (final runtime in [runtimes.first, second]) {
      when(
        () => service.installOrUpdate(
          session,
          runtime.definition,
          update: true,
          current: runtime,
          onOutput: any(named: 'onOutput'),
        ),
      ).thenAnswer(
        (_) async =>
            const AgentRuntimeActionResult(succeeded: true, output: 'updated'),
      );
    }
    await pumpScreen(tester);

    expect(find.text('2 updates available'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-update-all')));
    await tester.pumpAndSettle();

    expect(find.text('All agents updated'), findsOneWidget);
    expect(find.text('2 agents are up to date.'), findsOneWidget);
    for (final runtime in [runtimes.first, second]) {
      verify(
        () => service.installOrUpdate(
          session,
          runtime.definition,
          update: true,
          current: runtime,
          onOutput: any(named: 'onOutput'),
        ),
      ).called(1);
    }
  });

  testWidgets('action errors clear progress and show a failure dialog', (
    tester,
  ) async {
    when(
      () => service.installOrUpdate(
        session,
        agentCliRuntimeDefinitions.first,
        update: true,
        current: runtimes.first,
        onOutput: any(named: 'onOutput'),
      ),
    ).thenThrow(StateError('connection closed'));
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('agent-action-cli:claude')));
    await tester.pumpAndSettle();

    expect(find.text('Claude Code failed'), findsOneWidget);
    expect(find.textContaining('connection closed'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('agent-action-cli:claude')),
      findsOneWidget,
    );
  });

  testWidgets('update action shows result and refreshes providers', (
    tester,
  ) async {
    when(
      () => service.installOrUpdate(
        session,
        agentCliRuntimeDefinitions.first,
        update: true,
        current: runtimes.first,
        onOutput: any(named: 'onOutput'),
      ),
    ).thenAnswer((invocation) async {
      final onOutput =
          invocation.namedArguments[#onOutput] as ValueChanged<String>?;
      onOutput?.call('updated package');
      return const AgentRuntimeActionResult(
        succeeded: true,
        output: 'updated package',
        exitCode: 0,
      );
    });
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('agent-action-cli:claude')));
    await tester.pumpAndSettle();

    expect(find.text('Claude Code ready'), findsOneWidget);
    expect(find.text('updated package'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    verify(
      () => service.installOrUpdate(
        session,
        agentCliRuntimeDefinitions.first,
        update: true,
        current: runtimes.first,
        onOutput: any(named: 'onOutput'),
      ),
    ).called(1);
    verify(() => service.refreshAll(session)).called(2);
  });
}
