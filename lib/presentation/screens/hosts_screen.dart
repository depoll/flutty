import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/group_repository.dart';
import '../../data/repositories/host_repository.dart';
import '../../domain/services/ssh_service.dart';

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
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(host.label),
              subtitle: Text('${connectionIds.length} active connections'),
            ),
            for (final connectionId in connectionIds.reversed)
              ListTile(
                leading: const Icon(Icons.terminal),
                title: Text('Connection #$connectionId'),
                subtitle: Text(
                  '${host.username}@${host.hostname}:${host.port}',
                ),
                onTap: () => Navigator.pop(context, '$connectionId'),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New connection'),
              onTap: () => Navigator.pop(context, 'new'),
            ),
          ],
        ),
      ),
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
    final selectedGroup = await showModalBottomSheet<int?>(
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
              return Column(
                mainAxisSize: MainAxisSize.min,
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
                  ListTile(
                    leading: const Icon(Icons.list),
                    title: const Text('All hosts'),
                    selected: _selectedGroupId == null,
                    onTap: () => Navigator.pop(context),
                  ),
                  for (final group in groups)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(group.name),
                      selected: _selectedGroupId == group.id,
                      trailing: _selectedGroupId == group.id
                          ? Icon(Icons.check, color: theme.colorScheme.primary)
                          : null,
                      onTap: () => Navigator.pop(context, group.id),
                    ),
                  if (groups.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Text(
                        'No groups yet. Create one to organize hosts.',
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );

    if (!mounted) {
      return;
    }

    setState(() => _selectedGroupId = selectedGroup);
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
      subtitle: Text(
        connectionIds.isEmpty
            ? '${host.username}@${host.hostname}:${host.port}'
            : '${host.username}@${host.hostname}:${host.port}  •  '
                  '${connectionIds.length} connection(s)',
        style: theme.textTheme.bodySmall,
      ),
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

/// Provider for all hosts - uses stream for auto-refresh on changes.
final allHostsProvider = StreamProvider<List<Host>>((ref) {
  final repo = ref.watch(hostRepositoryProvider);
  return repo.watchAll();
});
