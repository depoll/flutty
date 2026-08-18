/// The Agents overview panel shown in the home shell.
///
/// Lists active and recent ACP sessions grouped by host, each with provider,
/// status, working-directory summary, last activity, and a pending-permission
/// indicator. Offers refresh, reconnect, and stop actions and a bottom-reachable
/// New Session action. Renders branded loading, error, and empty states.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/models/acp_recent_session.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/local_notification_service.dart';
import '../providers/entity_list_providers.dart';
import 'acp_new_session_sheet.dart';
import 'acp_session_presentation.dart';
import 'acp_session_switcher.dart';
import 'brand_empty_state.dart';
import 'brand_error_state.dart';
import 'panel_header.dart';

/// The Agents overview panel.
class AgentsPanel extends ConsumerStatefulWidget {
  /// Creates the Agents panel.
  const AgentsPanel({super.key});

  @override
  ConsumerState<AgentsPanel> createState() => _AgentsPanelState();
}

class _AgentsPanelState extends ConsumerState<AgentsPanel> {
  late Future<List<AcpRecentSessionRef>> _recents;

  @override
  void initState() {
    super.initState();
    _recents = _loadRecents();
  }

  Future<List<AcpRecentSessionRef>> _loadRecents() =>
      ref.read(acpSessionManagerProvider).loadRecentSessions();

  void _refresh() {
    setState(() => _recents = _loadRecents());
  }

  void _openChat(AcpSessionKey key) {
    context.push<void>(
      buildAgentChatLocation(
        hostId: key.hostId,
        providerId: key.providerId,
        bridgeId: key.bridgeId,
        acpSessionId: key.acpSessionId,
      ),
    );
  }

  Future<void> _newSession() async {
    final key = await showAcpNewSessionSheet(context);
    if (key != null && mounted) {
      _openChat(key);
    }
  }

  Future<void> _stop(AcpSessionKey key) async {
    await ref.read(acpSessionManagerProvider).stopSession(key);
    if (mounted) {
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final managerAsync = ref.watch(acpSessionManagerStateProvider);
    // Seed from the manager's synchronous snapshot so the overview renders on
    // the first frame instead of waiting for the state stream's first event.
    final managerState =
        managerAsync.asData?.value ??
        ref.watch(acpSessionManagerProvider).state;
    final hostsAsync = ref.watch(allHostsProvider);

    return Column(
      children: [
        PanelHeader(
          title: 'agents',
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
            ),
          ],
        ),
        Expanded(
          child: managerAsync.hasError
              ? BrandErrorState(
                  title: 'couldn’t load agents',
                  message: 'The agent workspace failed to load.',
                  onRetry: _refresh,
                )
              : FutureBuilder<List<AcpRecentSessionRef>>(
                  future: _recents,
                  builder: (context, snapshot) {
                    final entries = buildAcpSwitcherEntries(
                      sessions: managerState.sessions,
                      recents: snapshot.data ?? const <AcpRecentSessionRef>[],
                    );
                    if (entries.isEmpty) {
                      return _buildEmpty();
                    }
                    return _buildList(
                      entries,
                      hostsAsync.asData?.value ?? const [],
                    );
                  },
                ),
        ),
        _buildBottomAction(),
      ],
    );
  }

  Widget _buildEmpty() => const Center(
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: FluttyTheme.spacingLg),
      child: BrandEmptyState(
        title: 'no agent sessions yet',
        message:
            'Start an agent on a saved host, or resume one after it appears.',
      ),
    ),
  );

  Widget _buildList(List<AcpSwitcherEntry> entries, List<Host> hosts) {
    final labels = {for (final host in hosts) host.id: host.label};
    // Group by host, preserving the recency order of the first appearance.
    final order = <int>[];
    final grouped = <int, List<AcpSwitcherEntry>>{};
    for (final entry in entries) {
      final hostId = entry.session?.key.hostId ?? entry.recent!.hostId;
      grouped
          .putIfAbsent(hostId, () {
            order.add(hostId);
            return <AcpSwitcherEntry>[];
          })
          .add(entry);
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: FluttyTheme.spacingSm),
      children: [
        for (final hostId in order) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FluttyTheme.spacingLg,
              FluttyTheme.spacingMd,
              FluttyTheme.spacingLg,
              FluttyTheme.spacingXs,
            ),
            child: Text(
              labels[hostId] ?? 'host $hostId',
              style: FluttyTheme.displayMono(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final entry in grouped[hostId]!)
            _AgentSessionRow(
              entry: entry,
              onOpen: () => _openChat(entry.session?.key ?? entry.recent!.key),
              onStop: entry.session != null
                  ? () => _stop(entry.session!.key)
                  : null,
            ),
        ],
      ],
    );
  }

  Widget _buildBottomAction() => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingMd,
        FluttyTheme.spacingMd,
      ),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _newSession,
          icon: const Icon(Icons.add),
          label: const Text('New session'),
        ),
      ),
    ),
  );
}

class _AgentSessionRow extends StatelessWidget {
  const _AgentSessionRow({
    required this.entry,
    required this.onOpen,
    this.onStop,
  });

  final AcpSwitcherEntry entry;
  final VoidCallback onOpen;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final session = entry.session;
    final status = session != null
        ? acpStatusDisplay(session.status)
        : const AcpStatusDisplay(
            label: 'recent',
            icon: Icons.history,
            tone: AcpStatusTone.neutral,
          );
    final cwd = session?.cwd ?? entry.recent?.cwd;
    final activity = session?.lastActivityAt ?? entry.recent?.lastActivityAt;
    final providerLabel = session?.providerLabel ?? 'Agent';
    final needsPermission =
        (session?.pendingPermissions.isNotEmpty ?? false) ||
        (session?.pendingWrites.isNotEmpty ?? false);
    final canResume = session == null || !session.isLive;
    return ListTile(
      onTap: onOpen,
      minVerticalPadding: 12,
      leading: Icon(
        status.icon,
        color: acpStatusColor(colorScheme, status.tone),
      ),
      title: Text(entry.title, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$providerLabel · ${acpCwdSummary(cwd)} · ${status.label}'
        '${activity != null ? ' · ${acpRelativeTime(activity)}' : ''}',
        style: FluttyTheme.monoStyle.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (needsPermission)
            Tooltip(
              message: 'Needs permission',
              child: Icon(Icons.pending_actions, color: colorScheme.tertiary),
            ),
          if (canResume)
            TextButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.history, size: 18),
              label: const Text('Resume'),
            ),
          if (!canResume || onStop != null)
            PopupMenuButton<_RowAction>(
              icon: const Icon(Icons.more_vert),
              onSelected: (action) {
                switch (action) {
                  case _RowAction.open:
                    onOpen();
                  case _RowAction.stop:
                    onStop?.call();
                }
              },
              itemBuilder: (context) => [
                if (!canResume)
                  const PopupMenuItem(
                    value: _RowAction.open,
                    child: ListTile(
                      leading: Icon(Icons.open_in_new),
                      title: Text('Open'),
                    ),
                  ),
                if (onStop != null)
                  const PopupMenuItem(
                    value: _RowAction.stop,
                    child: ListTile(
                      leading: Icon(Icons.stop_circle_outlined),
                      title: Text('Stop'),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

enum _RowAction { open, stop }
