// Development-only native preview with deterministic agent states. No SSH runs.
// flutter run --flavor private -t tool/agent_management_preview.dart -d <device>
// Use --dart-define=AGENT_PREVIEW_PRO=false to preview the locked state.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/app/theme.dart';
import 'package:monkeyssh/domain/models/agent_runtime_info.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/agent_management_service.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/screens/agent_management_screen.dart';

const _pro = bool.fromEnvironment('AGENT_PREVIEW_PRO', defaultValue: true);
const _access = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.unavailable,
  entitlements: _pro
      ? MonetizationEntitlements.pro()
      : MonetizationEntitlements.free(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    ProviderScope(
      overrides: [
        monetizationServiceProvider.overrideWithValue(_PreviewBilling()),
        monetizationStateProvider.overrideWith((ref) => Stream.value(_access)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: FluttyTheme.light,
        darkTheme: FluttyTheme.dark,
        home: AgentManagementScreen(
          session: _PreviewSession(),
          service: _PreviewManagement(),
        ),
      ),
    ),
  );
}

class _PreviewBilling extends Fake implements MonetizationService {
  @override
  MonetizationState get currentState => _access;
  @override
  Future<bool> canUseFeature(MonetizationFeature feature) async => _pro;
}

class _PreviewSession extends Fake implements SshSession {}

class _PreviewManagement extends Fake implements AgentManagementService {
  final _runtimes = [
    for (final definition in agentRuntimeDefinitions) _sample(definition),
  ];

  static AgentRuntimeInfo _sample(AgentRuntimeDefinition definition) {
    final id = definition.id;
    final status = switch (id) {
      'cli:claude' || 'cli:codex' => AgentRuntimeStatus.updateAvailable,
      'cli:copilot' || 'cli:antigravity' => AgentRuntimeStatus.installed,
      'cli:opencode' => AgentRuntimeStatus.needsRepair,
      _ => AgentRuntimeStatus.notInstalled,
    };
    final installed = status != AgentRuntimeStatus.notInstalled;
    final version = switch (id) {
      'cli:claude' => '2.1.44',
      'cli:codex' => '0.114.0',
      'cli:copilot' => '0.0.412',
      'cli:opencode' => '1.2.8',
      _ => '1.4.0',
    };
    return AgentRuntimeInfo(
      definition: definition,
      status: status,
      installedVersion: installed ? version : null,
      latestVersion: status == AgentRuntimeStatus.updateAvailable
          ? (id == 'cli:claude' ? '2.1.51' : '0.115.0')
          : version,
      executablePath: installed
          ? '/opt/homebrew/bin/${definition.executableNames.first}'
          : null,
      detectionSource: installed ? 'Homebrew' : null,
      managedByPackageManager: installed,
      message: status == AgentRuntimeStatus.needsRepair
          ? 'Required setup scripts did not run.'
          : null,
    );
  }

  @override
  Future<List<AgentRuntimeInfo>> refreshAll(SshSession session) async {
    await Future<void>.delayed(const Duration(milliseconds: 650));
    return List.of(_runtimes);
  }

  @override
  Future<AgentRuntimeInfo> inspect(
    SshSession session,
    AgentRuntimeDefinition definition, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 650));
    return _runtimes.firstWhere(
      (runtime) => runtime.definition.id == definition.id,
    );
  }

  @override
  Future<AgentRuntimeActionResult> installOrUpdate(
    SshSession session,
    AgentRuntimeDefinition definition, {
    required bool update,
    AgentRuntimeInfo? current,
    ValueChanged<String>? onOutput,
  }) async {
    onOutput?.call('Checking installation…\n');
    await Future<void>.delayed(const Duration(seconds: 2));
    onOutput?.call('Installing package…\n');
    await Future<void>.delayed(const Duration(seconds: 2));
    final index = _runtimes.indexWhere(
      (runtime) => runtime.definition.id == definition.id,
    );
    _runtimes[index] = AgentRuntimeInfo(
      definition: definition,
      status: AgentRuntimeStatus.installed,
      installedVersion: current?.latestVersion ?? '1.4.0',
      latestVersion: current?.latestVersion ?? '1.4.0',
      executablePath:
          current?.executablePath ??
          '/opt/homebrew/bin/${definition.executableNames.first}',
      detectionSource: 'Homebrew',
      managedByPackageManager: true,
    );
    return const AgentRuntimeActionResult(
      succeeded: true,
      output: 'Package installed.',
    );
  }
}
