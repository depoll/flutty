import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/services/background_ssh_service.dart';
import '../../domain/services/ssh_service.dart';

/// The main home screen - Termius-style sidebar layout.
class HomeScreen extends ConsumerStatefulWidget {
  /// Creates a new [HomeScreen].
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _selectedIndex = 0;

  // Breakpoint for switching between mobile and desktop layout
  static const double _mobileBreakpoint = 600;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth >= _mobileBreakpoint;

    return isWide ? _buildDesktopLayout() : _buildMobileLayout();
  }

  Widget _buildMobileLayout() => Scaffold(
    appBar: AppBar(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.asset(
              'assets/icons/monkeyssh_icon.png',
              width: 28,
              height: 28,
            ),
          ),
          const SizedBox(width: 8),
          const Text('MonkeySSH'),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => context.push('/settings'),
        ),
      ],
    ),
    body: _buildContent(),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _selectedIndex,
      onDestinationSelected: (index) => setState(() => _selectedIndex = index),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      height: 65,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.dns_outlined),
          selectedIcon: Icon(Icons.dns_rounded),
          label: 'Hosts',
        ),
        NavigationDestination(
          icon: Icon(Icons.link_outlined),
          selectedIcon: Icon(Icons.link),
          label: 'Connections',
        ),
        NavigationDestination(
          icon: Icon(Icons.key_outlined),
          selectedIcon: Icon(Icons.key_rounded),
          label: 'Keys',
        ),
        NavigationDestination(
          icon: Icon(Icons.code_outlined),
          selectedIcon: Icon(Icons.code_rounded),
          label: 'Snippets',
        ),
      ],
    ),
  );

  Widget _buildDesktopLayout() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Row(
        children: [
          // Sidebar navigation
          Container(
            width: 220,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F0F14) : Colors.grey.shade50,
              border: Border(
                right: BorderSide(color: colorScheme.outline.withAlpha(60)),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  // App header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.asset(
                            'assets/icons/monkeyssh_icon.png',
                            width: 28,
                            height: 28,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'MonkeySSH',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Navigation items
                  _NavItem(
                    icon: Icons.dns_rounded,
                    label: 'Hosts',
                    selected: _selectedIndex == 0,
                    onTap: () => setState(() => _selectedIndex = 0),
                  ),
                  _NavItem(
                    icon: Icons.link,
                    label: 'Connections',
                    selected: _selectedIndex == 1,
                    onTap: () => setState(() => _selectedIndex = 1),
                  ),
                  _NavItem(
                    icon: Icons.key_rounded,
                    label: 'Keys',
                    selected: _selectedIndex == 2,
                    onTap: () => setState(() => _selectedIndex = 2),
                  ),
                  _NavItem(
                    icon: Icons.code_rounded,
                    label: 'Snippets',
                    selected: _selectedIndex == 3,
                    onTap: () => setState(() => _selectedIndex = 3),
                  ),

                  const Spacer(),

                  // Settings at bottom
                  _NavItem(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    selected: false,
                    onTap: () => context.push('/settings'),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),

          // Main content
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_selectedIndex) {
      case 0:
        return const _HostsPanel();
      case 1:
        return const _ConnectionsPanel();
      case 2:
        return const _KeysPanel();
      case 3:
        return const _SnippetsPanel();
      default:
        return const _HostsPanel();
    }
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected
            ? colorScheme.primary.withAlpha(isDark ? 25 : 20)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurface.withAlpha(150),
                ),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.onSurface.withAlpha(200),
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HostsPanel extends ConsumerWidget {
  const _HostsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hostsAsync = ref.watch(_allHostsStreamProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header bar
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(60)),
            ),
          ),
          child: Row(
            children: [
              Text(
                'Hosts',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _ActionButton(
                icon: Icons.add,
                label: 'New Host',
                onTap: () => context.push('/hosts/add'),
                primary: true,
              ),
            ],
          ),
        ),

        // Hosts list
        Expanded(
          child: hostsAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (hosts) => hosts.isEmpty
                ? _buildEmptyState(context)
                : _buildHostsList(context, ref, hosts),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 40,
            color: colorScheme.onSurface.withAlpha(60),
          ),
          const SizedBox(height: 12),
          Text(
            'No hosts yet',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withAlpha(150),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Add a host to get started',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface.withAlpha(100),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => context.push('/hosts/add'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Host'),
          ),
        ],
      ),
    );
  }

  Widget _buildHostsList(
    BuildContext context,
    WidgetRef ref,
    List<Host> hosts,
  ) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 4),
    itemCount: hosts.length,
    itemBuilder: (context, index) {
      final host = hosts[index];
      return _HostRow(host: host);
    },
  );
}

class _HostRow extends ConsumerWidget {
  const _HostRow({required this.host});

  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final connectionStates = ref.watch(activeSessionsProvider);
    final connectionIds = sessionsNotifier.getConnectionsForHost(host.id);
    final hostConnectionStates = connectionIds
        .map((connectionId) => connectionStates[connectionId])
        .whereType<SshConnectionState>()
        .toList(growable: false);
    final isConnected = hostConnectionStates.any(
      (state) => state == SshConnectionState.connected,
    );
    final isConnecting = hostConnectionStates.any(
      (state) =>
          state == SshConnectionState.connecting ||
          state == SshConnectionState.authenticating,
    );
    final connectionCount = connectionIds.length;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(_openHostConnection(context, ref)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(30)),
            ),
          ),
          child: Row(
            children: [
              // Status indicator
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isConnected
                      ? colorScheme.primary
                      : isConnecting
                      ? Colors.orange
                      : colorScheme.onSurface.withAlpha(40),
                  boxShadow: isConnected && isDark
                      ? [
                          BoxShadow(
                            color: colorScheme.primary.withAlpha(100),
                            blurRadius: 6,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 12),

              // Host info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          host.label,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (connectionCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primary.withAlpha(20),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$connectionCount',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                        if (host.isFavorite) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.star_rounded,
                            size: 14,
                            color: Colors.amber.shade600,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${host.username}@${host.hostname}',
                      style: FluttyTheme.monoStyle.copyWith(
                        fontSize: 11,
                        color: colorScheme.onSurface.withAlpha(100),
                      ),
                    ),
                  ],
                ),
              ),

              // Port badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.outline.withAlpha(40),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  ':${host.port}',
                  style: FluttyTheme.monoStyle.copyWith(
                    fontSize: 10,
                    color: colorScheme.onSurface.withAlpha(120),
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Actions
              _SmallIconButton(
                icon: Icons.add,
                onTap: () => unawaited(_openNewConnection(context, ref)),
              ),
              _SmallIconButton(
                icon: Icons.edit_outlined,
                onTap: () => context.push('/hosts/edit/${host.id}'),
              ),
              _SmallIconButton(
                icon: Icons.more_vert,
                onTap: () => _showMenu(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openHostConnection(BuildContext context, WidgetRef ref) async {
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final connectionIds = sessionsNotifier.getConnectionsForHost(host.id);

    if (connectionIds.isEmpty) {
      await _openNewConnection(context, ref);
      return;
    }

    if (connectionIds.length == 1) {
      if (context.mounted) {
        unawaited(
          context.push(
            '/terminal/${host.id}?connectionId=${connectionIds.first}',
          ),
        );
      }
      return;
    }

    final selection = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        final connectionStates = ref.read(activeSessionsProvider);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(host.label),
                subtitle: Text('${connectionIds.length} active connections'),
              ),
              for (final connectionId in connectionIds.reversed)
                _ConnectionSelectionTile(
                  connectionId: connectionId,
                  state:
                      connectionStates[connectionId] ??
                      SshConnectionState.disconnected,
                  endpoint: '${host.username}@${host.hostname}:${host.port}',
                  createdAt: sessionsNotifier
                      .getSession(connectionId)
                      ?.createdAt,
                  onTap: () =>
                      Navigator.pop(context, 'connection:$connectionId'),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New connection'),
                onTap: () => Navigator.pop(context, 'new'),
              ),
            ],
          ),
        );
      },
    );

    if (!context.mounted || selection == null) {
      return;
    }

    if (selection == 'new') {
      await _openNewConnection(context, ref);
      return;
    }

    final selectedId = int.tryParse(selection.replaceFirst('connection:', ''));
    if (selectedId != null) {
      unawaited(context.push('/terminal/${host.id}?connectionId=$selectedId'));
    }
  }

  Future<void> _openNewConnection(BuildContext context, WidgetRef ref) async {
    final result = await ref
        .read(activeSessionsProvider.notifier)
        .connect(host.id, forceNew: true);

    if (!context.mounted) {
      return;
    }

    if (!result.success || result.connectionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'Connection failed')),
      );
      return;
    }

    unawaited(
      context.push('/terminal/${host.id}?connectionId=${result.connectionId}'),
    );
  }

  void _showMenu(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Duplicate'),
              onTap: () {
                Navigator.pop(context);
                unawaited(_duplicateHost(context, ref));
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: colorScheme.error),
              title: Text('Delete', style: TextStyle(color: colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(context, ref);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Host'),
        content: Text('Delete "${host.label}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && context.mounted) {
      await ref.read(hostRepositoryProvider).delete(host.id);
    }
  }

  Future<void> _duplicateHost(BuildContext context, WidgetRef ref) async {
    await ref
        .read(hostRepositoryProvider)
        .insert(
          HostsCompanion.insert(
            label: '${host.label} (copy)',
            hostname: host.hostname,
            port: drift.Value(host.port),
            username: host.username,
            password: drift.Value(host.password),
            keyId: drift.Value(host.keyId),
            groupId: drift.Value(host.groupId),
            jumpHostId: drift.Value(host.jumpHostId),
            color: drift.Value(host.color),
            tags: drift.Value(host.tags),
            terminalThemeLightId: drift.Value(host.terminalThemeLightId),
            terminalThemeDarkId: drift.Value(host.terminalThemeDarkId),
            terminalFontFamily: drift.Value(host.terminalFontFamily),
            isFavorite: drift.Value(host.isFavorite),
          ),
        );
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Host duplicated')));
    }
  }
}

class _ConnectionSelectionTile extends StatelessWidget {
  const _ConnectionSelectionTile({
    required this.connectionId,
    required this.state,
    required this.endpoint,
    required this.onTap,
    this.createdAt,
  });

  final int connectionId;
  final SshConnectionState state;
  final String endpoint;
  final DateTime? createdAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = createdAt == null
        ? endpoint
        : '$endpoint\nOpened ${_formatTime(createdAt!)}';
    return ListTile(
      leading: const Icon(Icons.terminal),
      title: Text('Connection #$connectionId'),
      subtitle: Text(subtitle),
      trailing: Text(
        _stateLabel(state),
        style: Theme.of(context).textTheme.labelMedium,
      ),
      onTap: onTap,
    );
  }

  String _stateLabel(SshConnectionState state) => switch (state) {
    SshConnectionState.connected => 'Connected',
    SshConnectionState.connecting => 'Connecting',
    SshConnectionState.authenticating => 'Auth',
    SshConnectionState.reconnecting => 'Reconnecting',
    SshConnectionState.error => 'Error',
    SshConnectionState.disconnected => 'Disconnected',
  };

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _ConnectionsPanel extends ConsumerWidget {
  const _ConnectionsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hostsAsync = ref.watch(_allHostsStreamProvider);
    final connectionStates = ref.watch(activeSessionsProvider);
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final connections = sessionsNotifier.getActiveConnections();
    final hosts = hostsAsync.asData?.value ?? <Host>[];
    final hostLookup = {for (final host in hosts) host.id: host};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(60)),
            ),
          ),
          child: Text(
            'Connections',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: connections.isEmpty
              ? _buildEmptyState(context)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: connections.length,
                  itemBuilder: (context, index) {
                    final connection = connections[index];
                    final host = hostLookup[connection.hostId];
                    final state =
                        connectionStates[connection.connectionId] ??
                        connection.state;
                    final endpoint =
                        '${connection.config.username}@'
                        '${connection.config.hostname}:${connection.config.port}';

                    return ListTile(
                      leading: Icon(
                        Icons.terminal,
                        color: state == SshConnectionState.connected
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                      title: Text(host?.label ?? 'Host ${connection.hostId}'),
                      subtitle: Text(
                        '$endpoint\nConnection #${connection.connectionId}',
                      ),
                      isThreeLine: true,
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Disconnect',
                        onPressed: () async {
                          await ref
                              .read(activeSessionsProvider.notifier)
                              .disconnect(connection.connectionId);
                          if (ref.read(activeSessionsProvider).isEmpty) {
                            unawaited(BackgroundSshService.stop());
                          }
                        },
                      ),
                      onTap: () => unawaited(
                        context.push(
                          '/terminal/${connection.hostId}'
                          '?connectionId=${connection.connectionId}',
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.link_off,
            size: 40,
            color: colorScheme.onSurface.withAlpha(60),
          ),
          const SizedBox(height: 12),
          Text(
            'No active connections',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withAlpha(150),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Open a host to create one',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface.withAlpha(100),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (primary) {
      return FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      );
    }

    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: colorScheme.onSurface.withAlpha(150)),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          color: colorScheme.onSurface.withAlpha(150),
        ),
      ),
    );
  }
}

class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          icon,
          size: 16,
          color: colorScheme.onSurface.withAlpha(100),
        ),
      ),
    );
  }
}

/// Provider for all hosts as stream.
final _allHostsStreamProvider = StreamProvider<List<Host>>((ref) {
  final repo = ref.watch(hostRepositoryProvider);
  return repo.watchAll();
});

/// Provider for all keys as stream.
final _allKeysStreamProvider = StreamProvider<List<SshKey>>((ref) {
  final repo = ref.watch(keyRepositoryProvider);
  return repo.watchAll();
});

class _KeysPanel extends ConsumerWidget {
  const _KeysPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final keysAsync = ref.watch(_allKeysStreamProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header bar
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(60)),
            ),
          ),
          child: Row(
            children: [
              Text(
                'SSH Keys',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _ActionButton(
                icon: Icons.add,
                label: 'Add Key',
                onTap: () => context.push('/keys/add'),
                primary: true,
              ),
            ],
          ),
        ),

        // Keys list
        Expanded(
          child: keysAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (keys) => keys.isEmpty
                ? _buildEmptyState(context)
                : _buildKeysList(context, ref, keys),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.key_outlined,
            size: 40,
            color: colorScheme.onSurface.withAlpha(60),
          ),
          const SizedBox(height: 12),
          Text(
            'No SSH keys yet',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withAlpha(150),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Generate or import a key',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface.withAlpha(100),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => context.push('/keys/add'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Key'),
          ),
        ],
      ),
    );
  }

  Widget _buildKeysList(
    BuildContext context,
    WidgetRef ref,
    List<SshKey> keys,
  ) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 4),
    itemCount: keys.length,
    itemBuilder: (context, index) {
      final key = keys[index];
      return _KeyRow(sshKey: key);
    },
  );
}

class _KeyRow extends ConsumerWidget {
  const _KeyRow({required this.sshKey});

  final SshKey sshKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showKeyDetails(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(30)),
            ),
          ),
          child: Row(
            children: [
              // Key icon
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF00C9FF).withAlpha(isDark ? 25 : 15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  _getKeyIcon(),
                  size: 16,
                  color: const Color(0xFF00C9FF),
                ),
              ),
              const SizedBox(width: 12),

              // Key info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sshKey.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sshKey.keyType.toUpperCase(),
                      style: FluttyTheme.monoStyle.copyWith(
                        fontSize: 10,
                        color: colorScheme.onSurface.withAlpha(100),
                      ),
                    ),
                  ],
                ),
              ),

              // Copy public key button
              _SmallIconButton(
                icon: Icons.copy,
                onTap: () => _copyPublicKey(context),
              ),
              _SmallIconButton(
                icon: Icons.delete_outline,
                onTap: () => _confirmDelete(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _getKeyIcon() {
    if (sshKey.keyType.toLowerCase().contains('ed25519')) {
      return Icons.enhanced_encryption;
    } else if (sshKey.keyType.toLowerCase().contains('rsa')) {
      return Icons.key;
    }
    return Icons.vpn_key;
  }

  void _copyPublicKey(BuildContext context) {
    Clipboard.setData(ClipboardData(text: sshKey.publicKey));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Public key copied')));
  }

  void _showKeyDetails(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.all(20),
          child: ListView(
            controller: scrollController,
            children: [
              // Handle bar
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(sshKey.name, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                sshKey.keyType.toUpperCase(),
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 20),
              Text('Public Key', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colorScheme.outline.withAlpha(60)),
                ),
                child: SelectableText(
                  sshKey.publicKey,
                  style: FluttyTheme.monoStyle.copyWith(fontSize: 11),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _copyPublicKey(context),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy Public Key'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Key'),
        content: Text('Delete "${sshKey.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && context.mounted) {
      await ref.read(keyRepositoryProvider).delete(sshKey.id);
    }
  }
}

/// Provider for all snippets as stream.
final _allSnippetsStreamProvider = StreamProvider<List<Snippet>>((ref) {
  final repo = ref.watch(snippetRepositoryProvider);
  return repo.watchAll();
});

/// Panel for displaying and managing snippets inline.
class _SnippetsPanel extends ConsumerWidget {
  const _SnippetsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final snippetsAsync = ref.watch(_allSnippetsStreamProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header bar
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(60)),
            ),
          ),
          child: Row(
            children: [
              Text(
                'Snippets',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _ActionButton(
                icon: Icons.add,
                label: 'Add Snippet',
                onTap: () => _showAddEditSnippetDialog(context, ref, null),
                primary: true,
              ),
            ],
          ),
        ),

        // Snippets list
        Expanded(
          child: snippetsAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (snippets) => snippets.isEmpty
                ? _buildEmptyState(context, ref)
                : _buildSnippetsList(context, ref, snippets),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.code_outlined,
            size: 40,
            color: colorScheme.onSurface.withAlpha(60),
          ),
          const SizedBox(height: 12),
          Text(
            'No snippets yet',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withAlpha(150),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Save commands you use often',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurface.withAlpha(100),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _showAddEditSnippetDialog(context, ref, null),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add Snippet'),
          ),
        ],
      ),
    );
  }

  Widget _buildSnippetsList(
    BuildContext context,
    WidgetRef ref,
    List<Snippet> snippets,
  ) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 4),
    itemCount: snippets.length,
    itemBuilder: (context, index) {
      final snippet = snippets[index];
      return _SnippetRow(snippet: snippet);
    },
  );

  static Future<void> _showAddEditSnippetDialog(
    BuildContext context,
    WidgetRef ref,
    Snippet? existing,
  ) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final commandController = TextEditingController(
      text: existing?.command ?? '',
    );
    final descriptionController = TextEditingController(
      text: existing?.description ?? '',
    );
    final formKey = GlobalKey<FormState>();

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: DraggableScrollableSheet(
          maxChildSize: 0.9,
          minChildSize: 0.5,
          initialChildSize: 0.7,
          expand: false,
          builder: (context, scrollController) => Form(
            key: formKey,
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(20),
              children: [
                // Handle bar
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  existing == null ? 'Add Snippet' : 'Edit Snippet',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Restart Docker',
                    prefixIcon: Icon(Icons.label),
                  ),
                  textInputAction: TextInputAction.next,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a name';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                    hintText: 'What this snippet does',
                    prefixIcon: Icon(Icons.description),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: commandController,
                  decoration: const InputDecoration(
                    labelText: 'Command',
                    hintText: 'docker restart {{container}}',
                    alignLabelWithHint: true,
                  ),
                  maxLines: 4,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a command';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  'Use {{variable}} for substitution',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          if (formKey.currentState!.validate()) {
                            Navigator.pop(context, true);
                          }
                        },
                        child: Text(existing == null ? 'Add' : 'Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (result ?? false) {
      final repo = ref.read(snippetRepositoryProvider);
      final description = descriptionController.text.isEmpty
          ? null
          : descriptionController.text;

      if (existing != null) {
        await repo.update(
          existing.copyWith(
            name: nameController.text,
            command: commandController.text,
            description: drift.Value(description),
          ),
        );
      } else {
        await repo.insert(
          SnippetsCompanion.insert(
            name: nameController.text,
            command: commandController.text,
            description: drift.Value(description),
          ),
        );
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              existing == null ? 'Snippet added' : 'Snippet updated',
            ),
          ),
        );
      }
    }

    nameController.dispose();
    commandController.dispose();
    descriptionController.dispose();
  }
}

class _SnippetRow extends ConsumerWidget {
  const _SnippetRow({required this.snippet});

  final Snippet snippet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _copySnippet(context, ref),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colorScheme.outline.withAlpha(30)),
            ),
          ),
          child: Row(
            children: [
              // Snippet icon
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withAlpha(isDark ? 25 : 15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(Icons.code, size: 16, color: colorScheme.primary),
              ),
              const SizedBox(width: 12),

              // Snippet info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      snippet.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      snippet.command.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FluttyTheme.monoStyle.copyWith(
                        fontSize: 10,
                        color: colorScheme.onSurface.withAlpha(100),
                      ),
                    ),
                  ],
                ),
              ),

              // Actions
              _SmallIconButton(
                icon: Icons.copy,
                onTap: () => _copySnippet(context, ref),
              ),
              _SmallIconButton(
                icon: Icons.edit_outlined,
                onTap: () => _SnippetsPanel._showAddEditSnippetDialog(
                  context,
                  ref,
                  snippet,
                ),
              ),
              _SmallIconButton(
                icon: Icons.delete_outline,
                onTap: () => _confirmDelete(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _copySnippet(BuildContext context, WidgetRef ref) {
    Clipboard.setData(ClipboardData(text: snippet.command));
    unawaited(ref.read(snippetRepositoryProvider).incrementUsage(snippet.id));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied "${snippet.name}" to clipboard')),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Snippet'),
        content: Text('Delete "${snippet.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if ((confirmed ?? false) && context.mounted) {
      await ref.read(snippetRepositoryProvider).delete(snippet.id);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted "${snippet.name}"')));
      }
    }
  }
}
