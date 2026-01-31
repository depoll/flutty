import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/key_repository.dart';

/// Screen displaying list of SSH keys.
class KeysScreen extends ConsumerWidget {
  /// Creates a new [KeysScreen].
  const KeysScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keysAsync = ref.watch(_allKeysProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('SSH Keys')),
      body: keysAsync.when(
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
              Text('Error loading keys: $error'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.invalidate(_allKeysProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (keys) => _buildKeysList(context, ref, keys),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/keys/add'),
        icon: const Icon(Icons.add),
        label: const Text('Add Key'),
      ),
    );
  }

  Widget _buildKeysList(
    BuildContext context,
    WidgetRef ref,
    List<SshKey> keys,
  ) {
    if (keys.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.vpn_key_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No SSH keys yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap + to generate or import a key',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: keys.length,
      itemBuilder: (context, index) {
        final key = keys[index];
        return _KeyListTile(
          sshKey: key,
          onTap: () => _showKeyDetails(context, key),
          onDelete: () => _deleteKey(context, ref, key),
        );
      },
    );
  }

  void _showKeyDetails(BuildContext context, SshKey key) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (context, scrollController) =>
            _KeyDetailsSheet(sshKey: key, scrollController: scrollController),
      ),
    );
  }

  Future<void> _deleteKey(
    BuildContext context,
    WidgetRef ref,
    SshKey key,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Key'),
        content: Text('Are you sure you want to delete "${key.name}"?'),
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
      await ref.read(keyRepositoryProvider).delete(key.id);
      ref.invalidate(_allKeysProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted "${key.name}"')));
      }
    }
  }
}

class _KeyListTile extends StatelessWidget {
  const _KeyListTile({
    required this.sshKey,
    required this.onTap,
    required this.onDelete,
  });

  final SshKey sshKey;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Icon(_getKeyIcon(), color: theme.colorScheme.onPrimaryContainer),
      ),
      title: Text(sshKey.name),
      subtitle: Text(
        _getKeyTypeLabel(),
        style: theme.textTheme.bodySmall,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (action) {
          switch (action) {
            case 'delete':
              onDelete();
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'delete',
            child: Text(
              'Delete',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  IconData _getKeyIcon() {
    if (sshKey.keyType.toLowerCase().contains('ed25519')) {
      return Icons.enhanced_encryption;
    } else if (sshKey.keyType.toLowerCase().contains('rsa')) {
      return Icons.key;
    } else if (sshKey.keyType.toLowerCase().contains('ecdsa')) {
      return Icons.security;
    } else if (sshKey.keyType.toLowerCase().contains('dsa')) {
      return Icons.key_off;
    }
    return Icons.vpn_key;
  }

  String _getKeyTypeLabel() {
    final type = sshKey.keyType.toLowerCase();
    if (type == 'unknown') {
      // Try to extract from public key prefix
      final pubKey = sshKey.publicKey.trim();
      final firstSpace = pubKey.indexOf(' ');
      if (firstSpace > 0) {
        return pubKey.substring(0, firstSpace).toUpperCase();
      }
      return 'SSH Key';
    }
    return sshKey.keyType.toUpperCase();
  }
}

class _KeyDetailsSheet extends StatelessWidget {
  const _KeyDetailsSheet({
    required this.sshKey,
    required this.scrollController,
  });

  final SshKey sshKey;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      child: ListView(
        controller: scrollController,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outline.withAlpha(100),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Key name and type
          Text(sshKey.name, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            _getKeyTypeLabel(),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 24),

          // Public key
          Text('Public Key', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              sshKey.publicKey,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copyToClipboard(context, sshKey.publicKey),
            icon: const Icon(Icons.copy),
            label: const Text('Copy Public Key'),
          ),
          const SizedBox(height: 24),

          // Created date
          Text('Created', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            sshKey.createdAt.toString().split('.').first,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }

  String _getKeyTypeLabel() {
    final type = sshKey.keyType.toLowerCase();
    if (type == 'unknown') {
      // Try to extract from public key prefix
      final pubKey = sshKey.publicKey.trim();
      final firstSpace = pubKey.indexOf(' ');
      if (firstSpace > 0) {
        return pubKey.substring(0, firstSpace).toUpperCase();
      }
      return 'SSH Key';
    }
    return sshKey.keyType.toUpperCase();
  }
}

/// Provider for all SSH keys - uses stream for auto-refresh on changes.
final _allKeysProvider = StreamProvider<List<SshKey>>((ref) {
  final repo = ref.watch(keyRepositoryProvider);
  return repo.watchAll();
});
