import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/services/ssh_service.dart';
import '../providers/entity_list_providers.dart';
import 'brand_empty_state.dart';
import 'brand_error_state.dart';
import 'brand_list_skeleton.dart';
import 'host_port_forward_editor_sheet.dart';
import 'terminal_overlay_focus.dart';

/// Opens live port-forward controls for the current terminal connection.
Future<void> showTerminalPortForwardsSheet({
  required BuildContext context,
  required int hostId,
  required int connectionId,
  required SshSession session,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  requestFocus: terminalOverlayRouteRequestFocus(context),
  builder: (context) => DraggableScrollableSheet(
    initialChildSize: 0.68,
    minChildSize: 0.42,
    maxChildSize: 0.9,
    expand: false,
    builder: (context, scrollController) => _TerminalPortForwardsSheet(
      hostId: hostId,
      connectionId: connectionId,
      session: session,
      scrollController: scrollController,
    ),
  ),
);

class _TerminalPortForwardsSheet extends ConsumerStatefulWidget {
  const _TerminalPortForwardsSheet({
    required this.hostId,
    required this.connectionId,
    required this.session,
    required this.scrollController,
  });

  final int hostId;
  final int connectionId;
  final SshSession session;
  final ScrollController scrollController;

  @override
  ConsumerState<_TerminalPortForwardsSheet> createState() =>
      _TerminalPortForwardsSheetState();
}

class _TerminalPortForwardsSheetState
    extends ConsumerState<_TerminalPortForwardsSheet> {
  final Set<int> _pendingPortForwardIds = {};

  @override
  Widget build(BuildContext context) {
    final portForwards = ref.watch(portForwardsForHostProvider(widget.hostId));
    final activeSessionStates = ref.watch(activeSessionsProvider);
    final isConnected =
        activeSessionStates[widget.connectionId] ==
        SshConnectionState.connected;
    final automaticTunnels =
        ref
            .read(activeSessionsProvider.notifier)
            .getActiveTunnelsForHost(widget.hostId)
            .where((tunnel) => tunnel.isAutomatic)
            .toList(growable: false)
          ..sort((left, right) {
            if (left.isShellRelated != right.isShellRelated) {
              return left.isShellRelated ? -1 : 1;
            }
            return left.remotePort.compareTo(right.remotePort);
          });

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FluttyTheme.spacingMd,
            0,
            FluttyTheme.spacingSm,
            FluttyTheme.spacingSm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Port Forwards',
                      style: FluttyTheme.displayMono(
                        fontSize: 18,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: FluttyTheme.spacingXs),
                    Text(
                      'Live controls for this host',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (!isConnected)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(
              horizontal: FluttyTheme.spacingMd,
              vertical: FluttyTheme.spacingSm,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.link_off_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                const SizedBox(width: FluttyTheme.spacingSm),
                Expanded(
                  child: Text(
                    'Connection closed. Reconnect to change live forwards.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: StreamBuilder<void>(
            stream: widget.session.portForwardChanges,
            builder: (context, _) => portForwards.when(
              loading: () => const BrandListSkeleton(rowCount: 4),
              error: (_, _) => BrandErrorState(
                title: 'couldn’t load forwards',
                message: 'Saved forwards for this host didn’t load.',
                onRetry: () =>
                    ref.invalidate(portForwardsForHostProvider(widget.hostId)),
              ),
              data: (forwards) {
                if (forwards.isEmpty && automaticTunnels.isEmpty) {
                  return _buildEmptyState(context);
                }
                return _buildForwardList(
                  context,
                  forwards: forwards,
                  automaticTunnels: automaticTunnels,
                  isConnected: isConnected,
                );
              },
            ),
          ),
        ),
        if ((portForwards.asData?.value.isNotEmpty ?? false) ||
            automaticTunnels.isNotEmpty) ...[
          const Divider(height: 1),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.all(FluttyTheme.spacingMd),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _addForward,
                icon: const Icon(Icons.add),
                label: const Text('Add Forward'),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) => Center(
    child: SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(FluttyTheme.spacingLg),
      child: BrandEmptyState(
        title: 'no forwards for this host',
        message: 'Add a rule, then start it without leaving the terminal.',
        primaryLabel: 'Add Forward',
        onPrimary: _addForward,
      ),
    ),
  );

  Widget _buildForwardList(
    BuildContext context, {
    required List<PortForward> forwards,
    required List<ActiveTunnelInfo> automaticTunnels,
    required bool isConnected,
  }) => ListView(
    controller: widget.scrollController,
    padding: const EdgeInsets.symmetric(vertical: FluttyTheme.spacingSm),
    children: [
      if (automaticTunnels.isNotEmpty) ...[
        _buildGroupLabel(context, 'Detected automatically'),
        for (final tunnel in automaticTunnels) ...[
          _buildAutomaticForwardRow(context, tunnel),
          const Divider(height: 1),
        ],
      ],
      if (forwards.isNotEmpty) ...[
        if (automaticTunnels.isNotEmpty)
          _buildGroupLabel(context, 'Saved forwards'),
        for (var index = 0; index < forwards.length; index++) ...[
          _buildForwardRow(context, forwards[index], isConnected: isConnected),
          if (index < forwards.length - 1) const Divider(height: 1),
        ],
      ],
    ],
  );

  Widget _buildGroupLabel(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(
      FluttyTheme.spacingMd,
      FluttyTheme.spacingSm,
      FluttyTheme.spacingMd,
      FluttyTheme.spacingXs,
    ),
    child: Text(
      label.toLowerCase(),
      style: FluttyTheme.displayMono(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _buildAutomaticForwardRow(
    BuildContext context,
    ActiveTunnelInfo tunnel,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final proxyHost = tunnel.browserHost ?? tunnel.localHost;
    final proxyPort = tunnel.browserPort ?? tunnel.localPort;
    final endpoint = '$proxyHost:$proxyPort';
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        FluttyTheme.spacingXs,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingXs,
      ),
      leading: Icon(Icons.radar_rounded, color: colorScheme.primary),
      title: Text(
        endpoint,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: FluttyTheme.monoStyle.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${tunnel.remoteHost}:${tunnel.remotePort} → local proxy\n'
        '${tunnel.isShellRelated ? 'Started from connected shell' : 'Detected on host'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: FluttyTheme.monoStyle.copyWith(
          fontSize: 11,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: IconButton(
        tooltip: 'Copy $endpoint',
        onPressed: () => _copyAutomaticEndpoint(endpoint),
        icon: const Icon(Icons.copy_rounded),
      ),
    );
  }

  Future<void> _copyAutomaticEndpoint(String endpoint) async {
    await Clipboard.setData(ClipboardData(text: endpoint));
    if (mounted) {
      _showMessage('Copied $endpoint');
    }
  }

  Widget _buildForwardRow(
    BuildContext context,
    PortForward portForward, {
    required bool isConnected,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isActive = widget.session.isPortForwardActive(portForward.id);
    final isPending = _pendingPortForwardIds.contains(portForward.id);
    final isLocal = portForward.forwardType == 'local';
    final endpoint = isLocal
        ? '${portForward.localHost}:${portForward.localPort} → '
              '${portForward.remoteHost}:${portForward.remotePort}'
        : '${portForward.remoteHost}:${portForward.remotePort} → '
              '${portForward.localHost}:${portForward.localPort}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingSm,
      ),
      child: Row(
        children: [
          Icon(
            isLocal ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded,
            color: isActive
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: FluttyTheme.spacingMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  portForward.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: FluttyTheme.spacingXs),
                Text(
                  endpoint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: FluttyTheme.monoStyle.copyWith(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: FluttyTheme.spacingXs),
                Text(
                  [
                    if (isActive) 'Active now' else 'Stopped',
                    if (portForward.autoStart) 'Auto-start',
                  ].join(' • '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isActive
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                    fontWeight: isActive ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Edit ${portForward.name}',
            onPressed: () => _editForward(portForward),
            icon: const Icon(Icons.edit_outlined),
          ),
          SizedBox(
            width: 52,
            height: 48,
            child: Center(
              child: isPending
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Semantics(
                      label: isActive
                          ? 'Stop ${portForward.name}'
                          : 'Start ${portForward.name}',
                      toggled: isActive,
                      child: Switch(
                        value: isActive,
                        onChanged: !isConnected
                            ? null
                            : (enabled) => _setForwardActive(
                                portForward,
                                enabled: enabled,
                              ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _setForwardActive(
    PortForward portForward, {
    required bool enabled,
  }) async {
    if (_pendingPortForwardIds.contains(portForward.id)) {
      return;
    }
    setState(() => _pendingPortForwardIds.add(portForward.id));

    try {
      if (enabled) {
        final started = await widget.session.startPortForward(portForward);
        if (!started && mounted) {
          _showMessage(
            'Could not start "${portForward.name}". Check the configured ports.',
          );
        }
      } else {
        await widget.session.stopForward(portForward.id);
      }
    } on Exception catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'port forwards',
          context: ErrorDescription('while changing a live port forward'),
        ),
      );
      if (mounted) {
        _showMessage('Could not update "${portForward.name}". Try again.');
      }
    } finally {
      if (mounted) {
        setState(() => _pendingPortForwardIds.remove(portForward.id));
      }
    }
  }

  Future<void> _addForward() async {
    final result = await showHostPortForwardEditorSheet(
      context: context,
      hostId: widget.hostId,
      preferredConnectionId: widget.connectionId,
      requestFocus: terminalOverlayRouteRequestFocus(context),
    );
    if (result != null && mounted) {
      _showMessage(result.message);
    }
  }

  Future<void> _editForward(PortForward portForward) async {
    final result = await showHostPortForwardEditorSheet(
      context: context,
      hostId: widget.hostId,
      existing: portForward,
      preferredConnectionId: widget.connectionId,
      requestFocus: terminalOverlayRouteRequestFocus(context),
    );
    if (result != null && mounted) {
      _showMessage(result.message);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
