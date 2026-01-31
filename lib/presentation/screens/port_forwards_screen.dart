import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';

/// Screen displaying list of port forwards grouped by host.
class PortForwardsScreen extends ConsumerWidget {
  /// Creates a new [PortForwardsScreen].
  const PortForwardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final portForwardsAsync = ref.watch(_allPortForwardsProvider);
    final hostsAsync = ref.watch(_allHostsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Port Forwards')),
      body: portForwardsAsync.when(
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
              Text('Error: $error'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.invalidate(_allPortForwardsProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (portForwards) => hostsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => Center(child: Text('Error: $error')),
          data: (hosts) =>
              _buildPortForwardsList(context, ref, portForwards, hosts),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/port-forwards/add'),
        icon: const Icon(Icons.add),
        label: const Text('Add Forward'),
      ),
    );
  }

  Widget _buildPortForwardsList(
    BuildContext context,
    WidgetRef ref,
    List<PortForward> portForwards,
    List<Host> hosts,
  ) {
    if (portForwards.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.swap_horiz,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No port forwards yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap + to create a port forward rule',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    // Group port forwards by host
    final hostMap = {for (final h in hosts) h.id: h};
    final grouped = <int, List<PortForward>>{};
    for (final pf in portForwards) {
      grouped.putIfAbsent(pf.hostId, () => []).add(pf);
    }

    final hostIds = grouped.keys.toList();

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: hostIds.length,
      itemBuilder: (context, index) {
        final hostId = hostIds[index];
        final host = hostMap[hostId];
        final forwards = grouped[hostId]!;

        return _HostGroup(
          hostLabel: host?.label ?? 'Unknown Host',
          portForwards: forwards,
          onEdit: (pf) => context.push('/port-forwards/edit/${pf.id}'),
          onDelete: (pf) => _deletePortForward(context, ref, pf),
        );
      },
    );
  }

  Future<void> _deletePortForward(
    BuildContext context,
    WidgetRef ref,
    PortForward portForward,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Port Forward'),
        content: Text('Delete "${portForward.name}"?'),
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
      await ref.read(portForwardRepositoryProvider).delete(portForward.id);
      ref.invalidate(_allPortForwardsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "${portForward.name}"')),
        );
      }
    }
  }
}

class _HostGroup extends StatelessWidget {
  const _HostGroup({
    required this.hostLabel,
    required this.portForwards,
    required this.onEdit,
    required this.onDelete,
  });

  final String hostLabel;
  final List<PortForward> portForwards;
  final void Function(PortForward) onEdit;
  final void Function(PortForward) onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            hostLabel,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...portForwards.map(
          (pf) => Dismissible(
            key: ValueKey(pf.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16),
              color: theme.colorScheme.error,
              child: Icon(Icons.delete, color: theme.colorScheme.onError),
            ),
            confirmDismiss: (_) async {
              onDelete(pf);
              return false;
            },
            child: _PortForwardListTile(
              portForward: pf,
              onTap: () => onEdit(pf),
            ),
          ),
        ),
        const Divider(),
      ],
    );
  }
}

class _PortForwardListTile extends StatelessWidget {
  const _PortForwardListTile({required this.portForward, required this.onTap});

  final PortForward portForward;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLocal = portForward.forwardType == 'local';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isLocal
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.secondaryContainer,
        child: Icon(
          isLocal ? Icons.arrow_forward : Icons.arrow_back,
          color: isLocal
              ? theme.colorScheme.onPrimaryContainer
              : theme.colorScheme.onSecondaryContainer,
        ),
      ),
      title: Text(portForward.name),
      subtitle: Text(
        isLocal
            ? 'L ${portForward.localHost}:${portForward.localPort} → ${portForward.remoteHost}:${portForward.remotePort}'
            : 'R ${portForward.remoteHost}:${portForward.remotePort} → ${portForward.localHost}:${portForward.localPort}',
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: theme.colorScheme.outline,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (portForward.autoStart)
            Tooltip(
              message: 'Auto-start enabled',
              child: Icon(
                Icons.play_circle_outline,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
          const SizedBox(width: 8),
          Chip(
            label: Text(
              isLocal ? 'Local' : 'Remote',
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onSurface,
              ),
            ),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Provider for all port forwards.
final _allPortForwardsProvider = FutureProvider<List<PortForward>>((ref) async {
  final repo = ref.watch(portForwardRepositoryProvider);
  return repo.getAll();
});

/// Provider for all hosts.
final _allHostsProvider = FutureProvider<List<Host>>((ref) async {
  final repo = ref.watch(hostRepositoryProvider);
  return repo.getAll();
});
