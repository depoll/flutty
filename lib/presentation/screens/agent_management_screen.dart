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
        title: Text('Agent management', style: FluttyTheme.displayMono()),
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
            final horizontalPadding = constraints.maxWidth >= 700 ? 32.0 : 12.0;
            return ListView(
              key: const ValueKey('agent-management-list'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                12,
                horizontalPadding,
                32,
              ),
              children: [
                if (_refreshError != null)
                  _ErrorBanner(message: _refreshError!, onRetry: _refresh),
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
                const SizedBox(height: 24),
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: FluttyTheme.displayMono(fontSize: 17)),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      for (final runtime in runtimes)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _RuntimeCard(
            runtime: runtime,
            busy: runningActions.contains(runtime.definition.id),
            actionOutput: actionOutput[runtime.definition.id],
            onAction: () => onAction(runtime),
            onRecheck: () => onRecheck(runtime),
          ),
        ),
    ],
  );
}

class _RuntimeCard extends StatelessWidget {
  const _RuntimeCard({
    required this.runtime,
    required this.busy,
    required this.onAction,
    required this.onRecheck,
    this.actionOutput,
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
    final canInstall = runtime.status == AgentRuntimeStatus.notInstalled
        ? runtime.definition.supportsManagedInstall
        : runtime.status == AgentRuntimeStatus.updateAvailable &&
              runtime.managedByPackageManager;
    return Container(
      key: ValueKey('agent-runtime-${runtime.definition.id}'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: AgentToolIcon(
                  tool: runtime.definition.tool,
                  size: 23,
                  color: scheme.onSurfaceVariant,
                  fallbackIcon: Icons.hub_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      runtime.definition.label,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    _StatusLabel(presentation: status),
                    if (_sourceLine(runtime) case final source?) ...[
                      const SizedBox(height: 6),
                      Text(
                        source,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: FluttyTheme.monoStyle.copyWith(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (runtime.message case final message?) ...[
                      const SizedBox(height: 6),
                      Text(
                        message,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (busy && actionOutput != null && actionOutput!.trim().isNotEmpty)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 96),
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(10),
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
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (busy) ...[
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Text(
                  'Running remote command',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ] else if (canInstall)
                FilledButton.tonalIcon(
                  key: ValueKey('agent-action-${runtime.definition.id}'),
                  onPressed: onAction,
                  icon: Icon(
                    runtime.status == AgentRuntimeStatus.updateAvailable
                        ? Icons.upgrade_rounded
                        : Icons.download_rounded,
                  ),
                  label: Text(
                    runtime.status == AgentRuntimeStatus.updateAvailable
                        ? 'Update'
                        : 'Install',
                  ),
                )
              else
                TextButton.icon(
                  key: ValueKey('agent-recheck-${runtime.definition.id}'),
                  onPressed: onRecheck,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Re-check'),
                ),
            ],
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
      Icon(presentation.icon, size: 16, color: presentation.color),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          presentation.label,
          style: FluttyTheme.monoStyle.copyWith(
            fontSize: 12,
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
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
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
    scheme.primary,
  ),
  AgentRuntimeStatus.updateAvailable => _StatusPresentation(
    'Update available v${runtime.installedVersion ?? '?'} -> v${runtime.latestVersion ?? '?'}',
    Icons.upgrade_rounded,
    scheme.tertiary,
  ),
  AgentRuntimeStatus.notInstalled => _StatusPresentation(
    'Not installed${runtime.latestVersion == null ? '' : ' · latest v${runtime.latestVersion}'}',
    Icons.remove_circle_outline,
    scheme.onSurfaceVariant,
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
