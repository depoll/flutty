import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/snippet_repository.dart';

/// Screen displaying list of saved snippets.
class SnippetsScreen extends ConsumerWidget {
  /// Creates a new [SnippetsScreen].
  const SnippetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snippetsAsync = ref.watch(_allSnippetsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Snippets'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder),
            onPressed: () => _showFoldersDialog(context),
            tooltip: 'Folders',
          ),
        ],
      ),
      body: snippetsAsync.when(
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
                onPressed: () => ref.invalidate(_allSnippetsProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (snippets) => _buildSnippetsList(context, ref, snippets),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/snippets/add'),
        icon: const Icon(Icons.add),
        label: const Text('Add Snippet'),
      ),
    );
  }

  Widget _buildSnippetsList(
    BuildContext context,
    WidgetRef ref,
    List<Snippet> snippets,
  ) {
    if (snippets.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.code_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No snippets yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap + to create a snippet',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: snippets.length,
      itemBuilder: (context, index) {
        final snippet = snippets[index];
        return _SnippetListTile(
          snippet: snippet,
          onTap: () => _copySnippet(context, snippet),
          onEdit: () => context.push('/snippets/edit/${snippet.id}'),
          onDelete: () => _deleteSnippet(context, ref, snippet),
        );
      },
    );
  }

  void _copySnippet(BuildContext context, Snippet snippet) {
    Clipboard.setData(ClipboardData(text: snippet.command));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied "${snippet.name}" to clipboard')),
    );
  }

  Future<void> _deleteSnippet(
    BuildContext context,
    WidgetRef ref,
    Snippet snippet,
  ) async {
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
      await ref.read(snippetRepositoryProvider).delete(snippet.id);
      ref.invalidate(_allSnippetsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted "${snippet.name}"')));
      }
    }
  }

  void _showFoldersDialog(BuildContext context) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Folders coming soon')));
  }
}

class _SnippetListTile extends StatelessWidget {
  const _SnippetListTile({
    required this.snippet,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final Snippet snippet;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Icon(Icons.code, color: theme.colorScheme.onPrimaryContainer),
      ),
      title: Text(snippet.name),
      subtitle: Text(
        snippet.command.replaceAll('\n', ' '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: theme.colorScheme.outline,
        ),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (action) {
          switch (action) {
            case 'edit':
              onEdit();
            case 'delete':
              onDelete();
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
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
}

/// Provider for all snippets.
final _allSnippetsProvider = FutureProvider<List<Snippet>>((ref) async {
  final repo = ref.watch(snippetRepositoryProvider);
  return repo.getAll();
});
