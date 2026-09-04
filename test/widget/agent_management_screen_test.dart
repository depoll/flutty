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

    expect(find.text('Agent Management'), findsOneWidget);
    expect(find.text('agent CLIs'), findsOneWidget);
    expect(find.text('ACP adapters'), findsOneWidget);
    expect(find.text('Update v1.0.0 → v1.1.0'), findsOneWidget);
    expect(find.text('Homebrew · /opt/homebrew/bin/claude'), findsOneWidget);
    expect(find.text('Not installed · latest v1.0.0'), findsOneWidget);
    expect(find.text('Installed v1.0.0'), findsOneWidget);
  });

  testWidgets('compact rows avoid overflow on narrow phones', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    runtimes[0] = AgentRuntimeInfo(
      definition: agentCliRuntimeDefinitions.first,
      status: AgentRuntimeStatus.updateAvailable,
      installedVersion: '2026.08.12345',
      latestVersion: '2026.09.67890',
      executablePath:
          '/Users/developer/.local/share/version-manager/bin/claude-code',
      detectionSource: 'npm global package manager',
      managedByPackageManager: true,
    );

    await pumpScreen(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('agent-action-cli:claude')),
      findsOneWidget,
    );
  });

  testWidgets('repairs an agent with skipped install scripts', (tester) async {
    final broken = AgentRuntimeInfo(
      definition: agentCliRuntimeDefinitions.firstWhere(
        (definition) => definition.id == 'cli:opencode',
      ),
      status: AgentRuntimeStatus.needsRepair,
      executablePath: '/usr/local/bin/opencode',
      detectionSource: 'npm global',
      managedByPackageManager: true,
      message: 'Required setup scripts did not run.',
    );
    runtimes[1] = broken;
    when(
      () => service.installOrUpdate(
        session,
        broken.definition,
        update: false,
        current: broken,
        onOutput: any(named: 'onOutput'),
      ),
    ).thenAnswer((_) async {
      runtimes[1] = AgentRuntimeInfo(
        definition: broken.definition,
        status: AgentRuntimeStatus.installed,
        installedVersion: '0.5.2',
        executablePath: '/usr/local/bin/opencode',
        detectionSource: 'npm global',
        managedByPackageManager: true,
      );
      return const AgentRuntimeActionResult(
        succeeded: true,
        output: 'repaired',
      );
    });
    await pumpScreen(tester);

    expect(find.text('Needs repair'), findsOneWidget);
    await tester.tap(find.text('Repair'));
    await tester.pumpAndSettle();

    expect(find.text('OpenCode ready'), findsNothing);
    expect(find.text('Needs repair'), findsNothing);
    expect(find.text('Installed v0.5.2'), findsOneWidget);
    verify(
      () => service.installOrUpdate(
        session,
        broken.definition,
        update: false,
        current: broken,
        onOutput: any(named: 'onOutput'),
      ),
    ).called(1);
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
    final updates = [runtimes.first, second];
    for (final runtime in updates) {
      when(
        () => service.installOrUpdate(
          session,
          runtime.definition,
          update: true,
          current: runtime,
          onOutput: any(named: 'onOutput'),
        ),
      ).thenAnswer((_) async {
        final index = runtimes.indexWhere(
          (entry) => entry.definition.id == runtime.definition.id,
        );
        runtimes[index] = AgentRuntimeInfo(
          definition: runtime.definition,
          status: AgentRuntimeStatus.installed,
          installedVersion: runtime.latestVersion,
          executablePath: runtime.executablePath,
          detectionSource: runtime.detectionSource,
          managedByPackageManager: true,
        );
        return const AgentRuntimeActionResult(
          succeeded: true,
          output: 'updated',
        );
      });
    }
    await pumpScreen(tester);

    expect(find.text('2 updates available'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-update-all')));
    await tester.pumpAndSettle();

    expect(find.text('All agents updated'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    for (final runtime in updates) {
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

  testWidgets('successful update refreshes inline without a dialog', (
    tester,
  ) async {
    final current = runtimes.first;
    when(
      () => service.installOrUpdate(
        session,
        agentCliRuntimeDefinitions.first,
        update: true,
        current: current,
        onOutput: any(named: 'onOutput'),
      ),
    ).thenAnswer((invocation) async {
      final onOutput =
          invocation.namedArguments[#onOutput] as ValueChanged<String>?;
      onOutput?.call('updated package');
      runtimes[0] = AgentRuntimeInfo(
        definition: agentCliRuntimeDefinitions.first,
        status: AgentRuntimeStatus.installed,
        installedVersion: '1.1.0',
        executablePath: '/opt/homebrew/bin/claude',
        detectionSource: 'Homebrew',
        managedByPackageManager: true,
      );
      return const AgentRuntimeActionResult(
        succeeded: true,
        output: 'updated package',
        exitCode: 0,
      );
    });
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('agent-action-cli:claude')));
    await tester.pumpAndSettle();

    expect(find.text('Claude Code ready'), findsNothing);
    expect(find.text('updated package'), findsNothing);
    expect(find.text('Installed v1.1.0'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);

    verify(
      () => service.installOrUpdate(
        session,
        agentCliRuntimeDefinitions.first,
        update: true,
        current: current,
        onOutput: any(named: 'onOutput'),
      ),
    ).called(1);
    verify(() => service.refreshAll(session)).called(2);
  });
}
