import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/models/agent_runtime_info.dart';
import '../../domain/services/agent_management_service.dart';
import '../../domain/services/ssh_service.dart';
import '../widgets/agent_tool_icon.dart';

/// Manages coding-agent CLIs and ACP adapters on an active remote host.
class AgentManagementScreen extends ConsumerStatefulWidget {
  /// Creates the management screen for [session].
  const AgentManagementScreen({
    required this.session,
    this.service,
    this.onProvidersRefreshed,
    super.key,
  });

  /// Active remote SSH session.
  final SshSession session;

  /// Optional service override used by tests and embedded callers.
  final AgentManagementService? service;

  /// Called after remote probes invalidate and refresh provider discovery.
  final VoidCallback? onProvidersRefreshed;

  @override
  ConsumerState<AgentManagementScreen> createState() =>
      _AgentManagementScreenState();
}

class _AgentManagementScreenState extends ConsumerState<AgentManagementScreen> {
  late List<AgentRuntimeInfo> _runtimes;
  final Set<String> _runningActions = <String>{};
  final Map<String, String> _actionOutput = <String, String>{};
  bool _refreshing = false;
  bool _updatingAll = false;
  String? _refreshError;

  AgentManagementService get _service =>
      widget.service ?? ref.read(agentManagementServiceProvider);

  @override
  void initState() {
    super.initState();
    _runtimes = [
      for (final definition in agentRuntimeDefinitions)
        AgentRuntimeInfo(
          definition: definition,
          status: AgentRuntimeStatus.checking,
        ),
    ];
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    try {
      final runtimes = await _service.refreshAll(widget.session);
      if (!mounted) return;
      setState(() => _runtimes = runtimes);
      widget.onProvidersRefreshed?.call();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _refreshError = error.toString());
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _updateAll() async {
    final updates = _runtimes
        .where(
          (runtime) => runtime.status == AgentRuntimeStatus.updateAvailable,
        )
        .toList(growable: false);
    if (updates.isEmpty || _updatingAll) return;

    setState(() {
      _updatingAll = true;
      for (final runtime in updates) {
        _runningActions.add(runtime.definition.id);
        _actionOutput[runtime.definition.id] = '';
      }
    });
    final failures = <String>[];
    for (final runtime in updates) {
      final id = runtime.definition.id;
      try {
        final result = await _service.installOrUpdate(
          widget.session,
          runtime.definition,
          update: true,
          current: runtime,
          onOutput: (chunk) {
            if (!mounted) return;
            setState(() {
              final combined = '${_actionOutput[id] ?? ''}$chunk';
              _actionOutput[id] = combined.length <= 1200
                  ? combined
                  : combined.substring(combined.length - 1200);
            });
          },
        );
        if (!result.succeeded) failures.add(runtime.definition.label);
      } on Object {
        failures.add(runtime.definition.label);
      } finally {
        if (mounted) setState(() => _runningActions.remove(id));
      }
    }
    if (!mounted) return;
    setState(() => _updatingAll = false);
    await _refresh();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          failures.isEmpty ? Icons.check_circle_outline : Icons.error_outline,
          color: failures.isEmpty
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.error,
        ),
        title: Text(
          failures.isEmpty ? 'All agents updated' : 'Some updates failed',
        ),
        content: Text(
          failures.isEmpty
              ? '${updates.length} ${updates.length == 1 ? 'agent is' : 'agents are'} up to date.'
              : 'Could not update ${failures.join(', ')}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _runAction(AgentRuntimeInfo runtime) async {
    final id = runtime.definition.id;
    if (_runningActions.contains(id)) return;
    final update = runtime.status == AgentRuntimeStatus.updateAvailable;
    setState(() {
      _runningActions.add(id);
      _actionOutput[id] = '';
    });

    late final AgentRuntimeActionResult result;
    try {
      result = await _service.installOrUpdate(
        widget.session,
        runtime.definition,
        update: update,
        current: runtime,
        onOutput: (chunk) {
          if (!mounted) return;
          setState(() {
            final combined = '${_actionOutput[id] ?? ''}$chunk';
            _actionOutput[id] = combined.length <= 1200
                ? combined
                : combined.substring(combined.length - 1200);
          });
        },
      );
    } on Object catch (error) {
      result = AgentRuntimeActionResult(
        succeeded: false,
        output: 'The remote command could not be completed. $error',
      );
    } finally {
      if (mounted) {
        setState(() => _runningActions.remove(id));
      }
    }
    if (!mounted) return;
    await _showActionResult(runtime, result);
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _recheck(AgentRuntimeInfo runtime) async {
    final id = runtime.definition.id;
    if (_runningActions.contains(id)) return;
    setState(() => _runningActions.add(id));
    final updated = await _service.inspect(widget.session, runtime.definition);
    if (!mounted) return;
    setState(() {
      _runningActions.remove(id);
      final index = _runtimes.indexWhere(
        (entry) => entry.definition.id == runtime.definition.id,
      );
      if (index >= 0) _runtimes[index] = updated;
    });
  }

  Future<void> _showActionResult(
    AgentRuntimeInfo runtime,
    AgentRuntimeActionResult result,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(
        result.succeeded ? Icons.check_circle_outline : Icons.error_outline,
        color: result.succeeded
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.error,
      ),
      title: Text(
        result.succeeded
            ? '${runtime.definition.label} ready'
            : '${runtime.definition.label} failed',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 360),
        child: SingleChildScrollView(
          child: SelectableText(
            result.output.isEmpty
                ? result.succeeded
                      ? 'The remote command completed successfully.'
                      : 'The remote command did not return output.'
                : result.output,
            style: FluttyTheme.monoStyle.copyWith(fontSize: 12),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Agent Management', style: FluttyTheme.displayMono()),
        actions: [
          IconButton(
            key: const ValueKey('agent-management-refresh'),
            tooltip: 'Refresh agents',
            onPressed: _refreshing ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: _refreshing
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: colorScheme.primary,
                ),
              )
            : null,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = constraints.maxWidth >= 900
                ? (constraints.maxWidth - 840) / 2
                : constraints.maxWidth >= 700
                ? 32.0
                : 12.0;
            return ListView(
              key: const ValueKey('agent-management-list'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                8,
                horizontalPadding,
                24,
              ),
              children: [
                if (_refreshError != null)
                  _ErrorBanner(message: _refreshError!, onRetry: _refresh),
                if (_runtimes.where((runtime) => runtime.hasUpdate).toList()
                    case final updates when updates.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colorScheme.primary),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.system_update_alt_rounded,
                          size: 20,
                          color: colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${updates.length} ${updates.length == 1 ? 'update' : 'updates'} available',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: colorScheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        FilledButton(
                          key: const ValueKey('agent-update-all'),
                          onPressed: _updatingAll ? null : _updateAll,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                          child: Text(
                            _updatingAll ? 'Updating...' : 'Update all',
                          ),
                        ),
                      ],
                    ),
                  ),
                _RuntimeSection(
                  title: 'agent CLIs',
                  subtitle: 'Launch and resume tools available on this host',
                  runtimes: _runtimes
                      .where(
                        (runtime) =>
                            runtime.definition.kind == AgentRuntimeKind.cli,
                      )
                      .toList(growable: false),
                  runningActions: _runningActions,
                  actionOutput: _actionOutput,
                  onAction: _runAction,
                  onRecheck: _recheck,
                ),
                const SizedBox(height: 18),
                _RuntimeSection(
                  title: 'ACP adapters',
                  subtitle: 'Providers available to native agent windows',
                  runtimes: _runtimes
                      .where(
                        (runtime) =>
                            runtime.definition.kind ==
                            AgentRuntimeKind.acpAdapter,
                      )
                      .toList(growable: false),
                  runningActions: _runningActions,
                  actionOutput: _actionOutput,
                  onAction: _runAction,
                  onRecheck: _recheck,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RuntimeSection extends StatelessWidget {
  const _RuntimeSection({
    required this.title,
    required this.subtitle,
    required this.runtimes,
    required this.runningActions,
    required this.actionOutput,
    required this.onAction,
    required this.onRecheck,
  });

  final String title;
  final String subtitle;
  final List<AgentRuntimeInfo> runtimes;
  final Set<String> runningActions;
  final Map<String, String> actionOutput;
  final ValueChanged<AgentRuntimeInfo> onAction;
  final ValueChanged<AgentRuntimeInfo> onRecheck;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: FluttyTheme.displayMono(fontSize: 15)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Column(
              children: [
                for (var index = 0; index < runtimes.length; index++) ...[
                  _RuntimeRow(
                    runtime: runtimes[index],
                    busy: runningActions.contains(
                      runtimes[index].definition.id,
                    ),
                    actionOutput: actionOutput[runtimes[index].definition.id],
                    onAction: () => onAction(runtimes[index]),
                    onRecheck: () => onRecheck(runtimes[index]),
                  ),
                  if (index != runtimes.length - 1)
                    Divider(
                      height: 1,
                      indent: 54,
                      color: scheme.outlineVariant,
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RuntimeRow extends StatelessWidget {
  const _RuntimeRow({
    required this.runtime,
    required this.busy,
    required this.actionOutput,
    required this.onAction,
    required this.onRecheck,
  });

  final AgentRuntimeInfo runtime;
  final bool busy;
  final String? actionOutput;
  final VoidCallback onAction;
  final VoidCallback onRecheck;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = _statusPresentation(runtime, scheme);
    final canRepair =
        runtime.status == AgentRuntimeStatus.needsRepair &&
        runtime.definition.supportsManagedInstall;
    final canInstall =
        canRepair ||
        (runtime.status == AgentRuntimeStatus.notInstalled
            ? runtime.definition.supportsManagedInstall
            : runtime.status == AgentRuntimeStatus.updateAvailable &&
                  runtime.managedByPackageManager);
    return Container(
      key: ValueKey('agent-runtime-${runtime.definition.id}'),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: AgentToolIcon(
                  tool: runtime.definition.tool,
                  color: scheme.onSurfaceVariant,
                  fallbackIcon: Icons.hub_outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      runtime.definition.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _StatusLabel(presentation: status),
                    if (_sourceLine(runtime) case final source?) ...[
                      const SizedBox(height: 2),
                      Text(
                        source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FluttyTheme.monoStyle.copyWith(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (runtime.message case final message?) ...[
                      const SizedBox(height: 3),
                      Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                Semantics(
                  label: 'Running remote command',
                  child: const SizedBox.square(
                    dimension: 44,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                )
              else if (canInstall)
                OutlinedButton.icon(
                  key: ValueKey('agent-action-${runtime.definition.id}'),
                  onPressed: onAction,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 11),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(color: scheme.outline),
                  ),
                  icon: Icon(
                    runtime.status == AgentRuntimeStatus.updateAvailable
                        ? Icons.upgrade_rounded
                        : canRepair
                        ? Icons.build_outlined
                        : Icons.download_rounded,
                    size: 18,
                  ),
                  label: Text(
                    runtime.status == AgentRuntimeStatus.updateAvailable
                        ? 'Update'
                        : canRepair
                        ? 'Repair'
                        : 'Install',
                  ),
                )
              else
                IconButton(
                  key: ValueKey('agent-recheck-${runtime.definition.id}'),
                  tooltip: 'Re-check ${runtime.definition.label}',
                  onPressed: runtime.status == AgentRuntimeStatus.checking
                      ? null
                      : onRecheck,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                ),
            ],
          ),
          if (busy && actionOutput != null && actionOutput!.trim().isNotEmpty)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 88),
              margin: const EdgeInsets.fromLTRB(44, 8, 4, 0),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: SingleChildScrollView(
                reverse: true,
                child: Text(
                  actionOutput!.trim(),
                  style: FluttyTheme.monoStyle.copyWith(fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.presentation});

  final _StatusPresentation presentation;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(presentation.icon, size: 14, color: presentation.color),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          presentation.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: FluttyTheme.monoStyle.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: presentation.color,
          ),
        ),
      ),
    ],
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 20, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Could not refresh agents. $message',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _StatusPresentation {
  const _StatusPresentation(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}

_StatusPresentation _statusPresentation(
  AgentRuntimeInfo runtime,
  ColorScheme scheme,
) => switch (runtime.status) {
  AgentRuntimeStatus.checking => _StatusPresentation(
    'Checking...',
    Icons.sync_rounded,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.installed => _StatusPresentation(
    runtime.installedVersion == null
        ? 'Installed'
        : 'Installed v${runtime.installedVersion}',
    Icons.check_circle_outline,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.updateAvailable => _StatusPresentation(
    'Update v${runtime.installedVersion ?? '?'} → v${runtime.latestVersion ?? '?'}',
    Icons.upgrade_rounded,
    scheme.tertiary,
  ),
  AgentRuntimeStatus.notInstalled => _StatusPresentation(
    'Not installed${runtime.latestVersion == null ? '' : ' · latest v${runtime.latestVersion}'}',
    Icons.remove_circle_outline,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.needsRepair => _StatusPresentation(
    'Needs repair',
    Icons.build_circle_outlined,
    scheme.error,
  ),
  AgentRuntimeStatus.unavailable => _StatusPresentation(
    'Unavailable',
    Icons.block_outlined,
    scheme.onSurfaceVariant,
  ),
  AgentRuntimeStatus.failed => _StatusPresentation(
    'Check failed',
    Icons.error_outline,
    scheme.error,
  ),
};

String? _sourceLine(AgentRuntimeInfo runtime) {
  final path = runtime.executablePath;
  if (path == null) return null;
  final source = runtime.detectionSource;
  return source == null ? path : '$source · $path';
}
