import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/group_repository.dart';
import '../../data/repositories/host_repository.dart';
import '../../domain/models/terminal_theme.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/settings_service.dart';
import '../../domain/services/ssh_service.dart';
import '../../domain/services/terminal_theme_service.dart';
import '../widgets/connection_preview_snippet.dart';

/// Screen displaying list of saved hosts.
class HostsScreen extends ConsumerStatefulWidget {
  /// Creates a new [HostsScreen].
  const HostsScreen({super.key});

  @override
  ConsumerState<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends ConsumerState<HostsScreen> {
  String _searchQuery = '';
  int? _selectedGroupId;

  @override
  Widget build(BuildContext context) {
    final hostsAsync = ref.watch(allHostsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hosts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: _showSearchDialog,
            tooltip: 'Search',
          ),
          IconButton(
            icon: const Icon(Icons.folder),
            onPressed: _showGroupsDialog,
            tooltip: 'Groups',
          ),
        ],
      ),
      body: hostsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text('Error loading hosts: $error'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.invalidate(allHostsProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: _buildHostList,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/hosts/add'),
        icon: const Icon(Icons.add),
        label: const Text('Add Host'),
      ),
    );
  }

  Widget _buildHostList(List<Host> hosts) {
    var filteredHosts = hosts;

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filteredHosts = filteredHosts
          .where(
            (h) =>
                h.label.toLowerCase().contains(query) ||
                h.hostname.toLowerCase().contains(query) ||
                h.username.toLowerCase().contains(query),
          )
          .toList();
    }

    // Apply group filter
    if (_selectedGroupId != null) {
      filteredHosts = filteredHosts
          .where((h) => h.groupId == _selectedGroupId)
          .toList();
    }

    if (filteredHosts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _searchQuery.isNotEmpty ? Icons.search_off : Icons.dns_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No hosts match your search'
                  : 'No hosts yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (_searchQuery.isEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Tap + to add your first host',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: filteredHosts.length,
      itemBuilder: (context, index) {
        final host = filteredHosts[index];
        return _HostListTile(
          host: host,
          onTap: () => _connectToHost(host),
          onNewConnection: () => unawaited(_openNewConnection(host)),
          onEdit: () => context.push('/hosts/edit/${host.id}'),
          onDelete: () => _deleteHost(host),
        );
      },
    );
  }

  Future<void> _openNewConnection(Host host) async {
    final result = await ref
        .read(activeSessionsProvider.notifier)
        .connect(host.id, forceNew: true);
    if (!mounted) return;
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

  Future<void> _connectToHost(Host host) async {
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final connectionIds = sessionsNotifier.getConnectionsForHost(host.id);

    if (connectionIds.isEmpty) {
      final result = await sessionsNotifier.connect(host.id, forceNew: true);
      if (!mounted) return;
      if (!result.success || result.connectionId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Connection failed')),
        );
        return;
      }
      unawaited(
        context.push(
          '/terminal/${host.id}?connectionId=${result.connectionId}',
        ),
      );
      return;
    }

    if (connectionIds.length == 1) {
      unawaited(
        context.push(
          '/terminal/${host.id}?connectionId=${connectionIds.first}',
        ),
      );
      return;
    }

    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        final terminalThemeSettings = ref.read(terminalThemeSettingsProvider);
        final terminalThemes =
            ref.read(allTerminalThemesProvider).asData?.value ??
            TerminalThemes.all;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(host.label),
                subtitle: Text('${connectionIds.length} active connections'),
              ),
              for (final connectionId in connectionIds.reversed)
                () {
                  final connection = sessionsNotifier.getActiveConnection(
                    connectionId,
                  );
                  final preview = connection?.preview;
                  return ListTile(
                    leading: const Icon(Icons.terminal),
                    title: Text('Connection #$connectionId'),
                    subtitle: _HostPreviewText(
                      endpoint:
                          '${host.username}@${host.hostname}:${host.port}',
                      preview: preview,
                      terminalTheme: resolveConnectionPreviewTheme(
                        brightness: Theme.of(context).brightness,
                        themeSettings: terminalThemeSettings,
                        availableThemes: terminalThemes,
                        lightThemeId:
                            connection?.terminalThemeLightId ??
                            host.terminalThemeLightId,
                        darkThemeId:
                            connection?.terminalThemeDarkId ??
                            host.terminalThemeDarkId,
                      ),
                    ),
                    isThreeLine: preview?.trim().isNotEmpty ?? false,
                    onTap: () => Navigator.pop(context, '$connectionId'),
                  );
                }(),
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

    if (!mounted || selected == null) {
      return;
    }
    if (selected == 'new') {
      final result = await sessionsNotifier.connect(host.id, forceNew: true);
      if (!mounted) return;
      if (!result.success || result.connectionId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Connection failed')),
        );
        return;
      }
      unawaited(
        context.push(
          '/terminal/${host.id}?connectionId=${result.connectionId}',
        ),
      );
      return;
    }

    final connectionId = int.tryParse(selected);
    if (connectionId != null) {
      unawaited(
        context.push('/terminal/${host.id}?connectionId=$connectionId'),
      );
    }
  }

  Future<void> _deleteHost(Host host) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Host'),
        content: Text('Are you sure you want to delete "${host.label}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      await ref.read(hostRepositoryProvider).delete(host.id);
      ref.invalidate(allHostsProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted "${host.label}"')));
      }
    }
  }

  void _showSearchDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Search Hosts'),
        content: TextField(
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search by name, hostname, or username',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) {
            setState(() => _searchQuery = value);
            Navigator.pop(context);
          },
        ),
        actions: [
          if (_searchQuery.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() => _searchQuery = '');
                Navigator.pop(context);
              },
              child: const Text('Clear'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showGroupsDialog() async {
    final selection = await showModalBottomSheet<({int? groupId})>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        final groupRepo = ref.read(groupRepositoryProvider);

        return SafeArea(
          child: StreamBuilder<List<Group>>(
            stream: groupRepo.watchAll(),
            builder: (context, snapshot) {
              final groups = snapshot.data ?? const <Group>[];
              return SizedBox(
                height: 420,
                child: Column(
                  children: [
                    ListTile(
                      title: const Text('Groups'),
                      subtitle: Text(
                        _selectedGroupId == null
                            ? 'Showing all hosts'
                            : 'Filtered by selected group',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.create_new_folder_outlined),
                        tooltip: 'Create group',
                        onPressed: () {
                          Navigator.pop(context);
                          unawaited(_showCreateGroupDialog());
                        },
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.list),
                            title: const Text('All hosts'),
                            selected: _selectedGroupId == null,
                            onTap: () =>
                                Navigator.pop(context, (groupId: null)),
                          ),
                          for (final group in groups)
                            ListTile(
                              leading: const Icon(Icons.folder_outlined),
                              title: Text(group.name),
                              selected: _selectedGroupId == group.id,
                              trailing: _selectedGroupId == group.id
                                  ? Icon(
                                      Icons.check,
                                      color: theme.colorScheme.primary,
                                    )
                                  : null,
                              onTap: () =>
                                  Navigator.pop(context, (groupId: group.id)),
                            ),
                          if (groups.isEmpty)
                            const Padding(
                              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                              child: Text(
                                'No groups yet. Create one to organize hosts.',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    if (!mounted || selection == null) {
      return;
    }

    setState(() => _selectedGroupId = selection.groupId);
  }

  Future<void> _showCreateGroupDialog() async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final created = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Group'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Group name',
              hintText: 'Production',
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter a group name';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    final name = controller.text.trim();
    controller.dispose();
    if (created != true || name.isEmpty) {
      return;
    }

    final id = await ref
        .read(groupRepositoryProvider)
        .insert(GroupsCompanion.insert(name: name));
    if (!mounted) {
      return;
    }
    setState(() => _selectedGroupId = id);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Created group "$name"')));
  }
}

class _HostListTile extends ConsumerWidget {
  const _HostListTile({
    required this.host,
    required this.onTap,
    required this.onNewConnection,
    required this.onEdit,
    required this.onDelete,
  });

  final Host host;
  final VoidCallback onTap;
  final VoidCallback onNewConnection;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final connectionStates = ref.watch(activeSessionsProvider);
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final connectionIds = sessionsNotifier.getConnectionsForHost(host.id);
    final activeConnections = connectionIds
        .map(sessionsNotifier.getActiveConnection)
        .whereType<ActiveConnection>()
        .toList(growable: false);
    final states = connectionIds
        .map((connectionId) => connectionStates[connectionId])
        .whereType<SshConnectionState>()
        .toList(growable: false);
    final isConnected = states.any(
      (state) => state == SshConnectionState.connected,
    );
    final isConnecting = states.any(
      (state) =>
          state == SshConnectionState.connecting ||
          state == SshConnectionState.authenticating,
    );
    final previewConnections = activeConnections
        .where((connection) => connection.preview?.trim().isNotEmpty ?? false)
        .toList(growable: false);
    final latestConnection = activeConnections.isEmpty
        ? null
        : activeConnections.last;
    final latestPreviewConnection = previewConnections.isEmpty
        ? latestConnection
        : previewConnections.last;
    final stackedPreviewConnections = previewConnections.length <= 3
        ? previewConnections
        : previewConnections.sublist(previewConnections.length - 3);
    final terminalThemeSettings = ref.watch(terminalThemeSettingsProvider);
    final terminalThemes =
        ref.watch(allTerminalThemesProvider).asData?.value ??
        TerminalThemes.all;
    final previewTheme = resolveConnectionPreviewTheme(
      brightness: theme.brightness,
      themeSettings: terminalThemeSettings,
      availableThemes: terminalThemes,
      lightThemeId:
          latestPreviewConnection?.terminalThemeLightId ??
          host.terminalThemeLightId,
      darkThemeId:
          latestPreviewConnection?.terminalThemeDarkId ??
          host.terminalThemeDarkId,
    );
    final stackedPreviews = stackedPreviewConnections
        .map(
          (connection) => _StackedHostPreview(
            preview: connection.preview!.trim(),
            terminalTheme: resolveConnectionPreviewTheme(
              brightness: theme.brightness,
              themeSettings: terminalThemeSettings,
              availableThemes: terminalThemes,
              lightThemeId:
                  connection.terminalThemeLightId ?? host.terminalThemeLightId,
              darkThemeId:
                  connection.terminalThemeDarkId ?? host.terminalThemeDarkId,
            ),
          ),
        )
        .toList(growable: false);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isConnected
            ? Colors.green.withAlpha(50)
            : theme.colorScheme.surfaceContainerHighest,
        child: Icon(
          isConnected ? Icons.link : Icons.dns,
          color: isConnected ? Colors.green : theme.colorScheme.primary,
        ),
      ),
      title: Text(host.label),
      subtitle: _HostPreviewText(
        endpoint: connectionIds.isEmpty
            ? '${host.username}@${host.hostname}:${host.port}'
            : '${host.username}@${host.hostname}:${host.port}  •  '
                  '${connectionIds.length} connection(s)',
        preview: latestPreviewConnection?.preview,
        terminalTheme: previewTheme,
        stackedPreviews: stackedPreviews,
      ),
      isThreeLine: latestPreviewConnection?.preview?.trim().isNotEmpty ?? false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (host.isFavorite)
            const Icon(Icons.star, color: Colors.amber, size: 20),
          if (isConnecting)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New connection',
            onPressed: onNewConnection,
          ),
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'edit':
                  onEdit();
                case 'delete':
                  onDelete();
                case 'duplicate':
                  _duplicateHost(context, ref);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
              PopupMenuItem(
                value: 'delete',
                child: Text(
                  'Delete',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  Future<void> _duplicateHost(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(hostRepositoryProvider);
    await repo.insert(
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
      ),
    );
    ref.invalidate(allHostsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Host duplicated')));
    }
  }
}

class _HostPreviewText extends StatelessWidget {
  const _HostPreviewText({
    required this.endpoint,
    this.preview,
    this.terminalTheme,
    this.stackedPreviews = const [],
  });

  final String endpoint;
  final String? preview;
  final TerminalThemeData? terminalTheme;
  final List<_StackedHostPreview> stackedPreviews;

  @override
  Widget build(BuildContext context) {
    if (stackedPreviews.length > 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(endpoint),
          const SizedBox(height: 4),
          _StackedHostPreviewList(previews: stackedPreviews),
        ],
      );
    }

    return ConnectionPreviewSnippet(
      endpoint: endpoint,
      preview: preview,
      terminalTheme: terminalTheme,
    );
  }
}

class _StackedHostPreview {
  const _StackedHostPreview({required this.preview, this.terminalTheme});

  final String preview;
  final TerminalThemeData? terminalTheme;
}

class _StackedHostPreviewList extends StatelessWidget {
  const _StackedHostPreviewList({required this.previews});

  static const double _verticalOffset = 10;
  static const double _horizontalOffset = 6;

  final List<_StackedHostPreview> previews;

  @override
  Widget build(BuildContext context) {
    final stackHeight = 52 + ((previews.length - 1) * _verticalOffset);

    return SizedBox(
      width: double.infinity,
      height: stackHeight,
      child: Stack(
        children: [
          for (var index = 0; index < previews.length; index++)
            Positioned(
              top: index * _verticalOffset,
              left: index * _horizontalOffset,
              right: (previews.length - index - 1) * _horizontalOffset,
              child: ConnectionPreviewSnippet(
                endpoint: '',
                preview: previews[index].preview,
                terminalTheme: previews[index].terminalTheme,
                showEndpoint: false,
                previewMaxLines: 2,
              ),
            ),
        ],
      ),
    );
  }
}

/// Provider for all hosts - uses stream for auto-refresh on changes.
final allHostsProvider = StreamProvider<List<Host>>((ref) {
  final repo = ref.watch(hostRepositoryProvider);
  return repo.watchAll();
});
