import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/services/ssh_service.dart';
import '../providers/entity_list_providers.dart';
import 'brand_empty_state.dart';
import 'brand_error_state.dart';
import 'brand_list_skeleton.dart';
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
    final isConnected = ref.watch(
      activeSessionsProvider.select(
        (states) => states[widget.connectionId] == SshConnectionState.connected,
      ),
    );

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
                      'Live controls for this SSH connection',
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
              data: (forwards) => forwards.isEmpty
                  ? _buildEmptyState(context)
                  : ListView.separated(
                      controller: widget.scrollController,
                      padding: const EdgeInsets.symmetric(
                        vertical: FluttyTheme.spacingSm,
                      ),
                      itemCount: forwards.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) => _buildForwardRow(
                        context,
                        forwards[index],
                        isConnected: isConnected,
                      ),
                    ),
            ),
          ),
        ),
        if (portForwards.asData?.value.isNotEmpty ?? false) ...[
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

  Future<void> _addForward() => context.push<void>(
    '/port-forwards/add?hostId=${widget.hostId}'
    '&connectionId=${widget.connectionId}',
  );

  Future<void> _editForward(PortForward portForward) => context.push<void>(
    '/port-forwards/edit/${portForward.id}'
    '?connectionId=${widget.connectionId}',
  );

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
