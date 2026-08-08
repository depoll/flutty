import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
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
  required Future<void> Function(ActiveTunnelInfo tunnel) onOpenInBrowser,
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
      onOpenInBrowser: onOpenInBrowser,
      scrollController: scrollController,
    ),
  ),
);

class _TerminalPortForwardsSheet extends ConsumerStatefulWidget {
  const _TerminalPortForwardsSheet({
    required this.hostId,
    required this.connectionId,
    required this.session,
    required this.onOpenInBrowser,
    required this.scrollController,
  });

  final int hostId;
  final int connectionId;
  final SshSession session;
  final Future<void> Function(ActiveTunnelInfo tunnel) onOpenInBrowser;
  final ScrollController scrollController;

  @override
  ConsumerState<_TerminalPortForwardsSheet> createState() =>
      _TerminalPortForwardsSheetState();
}

class _TerminalPortForwardsSheetState
    extends ConsumerState<_TerminalPortForwardsSheet> {
  final Set<int> _pendingPortForwardIds = {};
  bool _isUpdatingAutoForwardPorts = false;

  @override
  Widget build(BuildContext context) {
    final portForwards = ref.watch(portForwardsForHostProvider(widget.hostId));
    final activeSessionStates = ref.watch(activeSessionsProvider);
    final autoForwardPorts = ref.watch(
      allHostsProvider.select((hosts) {
        for (final host in hosts.asData?.value ?? const <Host>[]) {
          if (host.id == widget.hostId) {
            return host.autoForwardPorts;
          }
        }
        return null;
      }),
    );
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
              data: (forwards) => ListView(
                controller: widget.scrollController,
                padding: const EdgeInsets.only(bottom: FluttyTheme.spacingSm),
                children: [
                  _buildAutoForwardToggle(
                    context,
                    autoForwardPorts: autoForwardPorts,
                    hasAutomaticTunnels: automaticTunnels.isNotEmpty,
                  ),
                  const Divider(height: 1),
                  if (forwards.isEmpty && automaticTunnels.isEmpty)
                    _buildEmptyState(context)
                  else
                    ..._buildForwardRows(
                      context,
                      forwards: forwards,
                      automaticTunnels: automaticTunnels,
                      isConnected: isConnected,
                    ),
                ],
              ),
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

  Widget _buildAutoForwardToggle(
    BuildContext context, {
    required bool? autoForwardPorts,
    required bool hasAutomaticTunnels,
  }) {
    final theme = Theme.of(context);
    final isEnabled = autoForwardPorts ?? false;
    return SwitchListTile.adaptive(
      key: const Key('terminal-auto-forward-ports-switch'),
      secondary: _isUpdatingAutoForwardPorts
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              Icons.radar_rounded,
              color: isEnabled
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
      title: const Text('Detect open ports'),
      subtitle: Text(switch ((isEnabled, hasAutomaticTunnels)) {
        (false, _) => 'Automatically proxy new remote listeners on this host',
        (true, true) => 'Proxying new remote listeners while connected',
        (true, false) => 'Watching this host for new remote listeners',
      }, style: theme.textTheme.bodySmall),
      value: isEnabled,
      onChanged: autoForwardPorts == null || _isUpdatingAutoForwardPorts
          ? null
          : (enabled) => unawaited(_setAutoForwardPorts(enabled: enabled)),
    );
  }

  Future<void> _setAutoForwardPorts({required bool enabled}) async {
    if (_isUpdatingAutoForwardPorts) {
      return;
    }
    setState(() => _isUpdatingAutoForwardPorts = true);
    try {
      final updated = await ref
          .read(hostRepositoryProvider)
          .setAutoForwardPorts(widget.hostId, enabled: enabled);
      if (!updated) {
        if (mounted) {
          _showMessage('Could not update automatic port detection.');
        }
        return;
      }
      await ref
          .read(activeSessionsProvider.notifier)
          .reconfigureAutomaticPortForwardingForHost(widget.hostId);
      if (mounted) {
        _showMessage(
          enabled
              ? 'Detecting open ports on this host.'
              : 'Stopped detecting open ports on this host.',
        );
      }
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'port forwards',
          context: ErrorDescription(
            'while changing automatic port forwarding for a host',
          ),
        ),
      );
      if (mounted) {
        _showMessage('Could not update automatic port detection.');
      }
    } finally {
      if (mounted) {
        setState(() => _isUpdatingAutoForwardPorts = false);
      }
    }
  }

  Widget _buildEmptyState(BuildContext context) => Padding(
    padding: const EdgeInsets.all(FluttyTheme.spacingLg),
    child: BrandEmptyState(
      title: 'no forwards for this host',
      message: 'Add a rule, then start it without leaving the terminal.',
      primaryLabel: 'Add Forward',
      onPrimary: _addForward,
    ),
  );

  List<Widget> _buildForwardRows(
    BuildContext context, {
    required List<PortForward> forwards,
    required List<ActiveTunnelInfo> automaticTunnels,
    required bool isConnected,
  }) => [
    if (automaticTunnels.any((tunnel) => tunnel.isShellRelated)) ...[
      _buildGroupLabel(context, 'This saved host'),
      for (final tunnel in automaticTunnels.where(
        (tunnel) => tunnel.isShellRelated,
      )) ...[
        _buildAutomaticForwardRow(context, tunnel),
        const Divider(height: 1),
      ],
    ],
    if (automaticTunnels.any((tunnel) => !tunnel.isShellRelated)) ...[
      _buildGroupLabel(context, 'Shared host services'),
      for (final tunnel in automaticTunnels.where(
        (tunnel) => !tunnel.isShellRelated,
      )) ...[
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
  ];

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
    final canOpenInBrowser =
        tunnel.browserHost != null && tunnel.browserPort != null;
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        FluttyTheme.spacingXs,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingXs,
      ),
      leading: Icon(Icons.radar_rounded, color: colorScheme.primary),
      onTap: canOpenInBrowser ? () => unawaited(_openInBrowser(tunnel)) : null,
      title: Text(
        'Port ${tunnel.remotePort}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: FluttyTheme.monoStyle.copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${tunnel.remoteHost}:${tunnel.remotePort} → $endpoint\n'
        '${tunnel.isShellRelated ? 'Started from this saved host' : 'Shared host service (Docker/background)'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: FluttyTheme.monoStyle.copyWith(
          fontSize: 11,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canOpenInBrowser)
            ExcludeSemantics(
              child: Icon(
                Icons.open_in_browser_rounded,
                size: 20,
                color: colorScheme.primary,
              ),
            ),
          IconButton(
            tooltip: 'Copy $endpoint',
            onPressed: () => _copyAutomaticEndpoint(endpoint),
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
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
    final activeTunnel = _activeTunnelForPortForward(portForward.id);
    final canOpenInBrowser =
        isLocal &&
        activeTunnel?.browserHost != null &&
        activeTunnel?.browserPort != null;
    final endpoint = isLocal
        ? '${portForward.localHost}:${portForward.localPort} → '
              '${portForward.remoteHost}:${portForward.remotePort}'
        : '${portForward.remoteHost}:${portForward.remotePort} → '
              '${portForward.localHost}:${portForward.localPort}';

    return Semantics(
      button: canOpenInBrowser,
      label: canOpenInBrowser
          ? 'Open ${portForward.name} in the in-app browser'
          : null,
      child: InkWell(
        onTap: canOpenInBrowser
            ? () => unawaited(_openInBrowser(activeTunnel!))
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            FluttyTheme.spacingMd,
            FluttyTheme.spacingSm,
            FluttyTheme.spacingSm,
            FluttyTheme.spacingSm,
          ),
          child: Row(
            children: [
              Icon(
                isLocal
                    ? Icons.arrow_forward_rounded
                    : Icons.arrow_back_rounded,
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
                            key: Key('port-forward-switch-${portForward.id}'),
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
        ),
      ),
    );
  }

  ActiveTunnelInfo? _activeTunnelForPortForward(int portForwardId) {
    for (final tunnel in widget.session.activeTunnels) {
      if (tunnel.portForwardId == portForwardId) {
        return tunnel;
      }
    }
    return null;
  }

  Future<void> _openInBrowser(ActiveTunnelInfo tunnel) =>
      widget.onOpenInBrowser(tunnel);

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
