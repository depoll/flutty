import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/snippet_repository.dart';

/// Screen displaying list of saved snippets.
class SnippetsScreen extends ConsumerStatefulWidget {
  /// Creates a new [SnippetsScreen].
  const SnippetsScreen({super.key});

  @override
  ConsumerState<SnippetsScreen> createState() => _SnippetsScreenState();
}

class _SnippetsScreenState extends ConsumerState<SnippetsScreen> {
  int? _selectedFolderId;
  String? _selectedFolderName;

  @override
  Widget build(BuildContext context) {
    final snippetsAsync = ref.watch(_snippetsProvider(_selectedFolderId));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Snippets'),
        bottom: _selectedFolderName == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(32),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Folder: $_selectedFolderName',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
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
                onPressed: () =>
                    ref.invalidate(_snippetsProvider(_selectedFolderId)),
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
      ref.invalidate(_snippetsProvider(_selectedFolderId));
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted "${snippet.name}"')));
      }
    }
  }

  Future<void> _showFoldersDialog(BuildContext context) async {
    final selection =
        await showModalBottomSheet<({int? folderId, String? folderName})>(
          context: context,
          showDragHandle: true,
          builder: (context) {
            final repo = ref.read(snippetRepositoryProvider);
            return SafeArea(
              child: StreamBuilder<List<SnippetFolder>>(
                stream: repo.watchAllFolders(),
                builder: (context, snapshot) {
                  final folders = snapshot.data ?? const <SnippetFolder>[];
                  return SizedBox(
                    height: 420,
                    child: Column(
                      children: [
                        ListTile(
                          title: const Text('Folders'),
                          subtitle: Text(
                            _selectedFolderId == null
                                ? 'Showing all snippets'
                                : 'Filtered by selected folder',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.create_new_folder_outlined),
                            tooltip: 'Create folder',
                            onPressed: () {
                              Navigator.pop(context);
                              unawaited(_showCreateFolderDialog());
                            },
                          ),
                        ),
                        Expanded(
                          child: ListView(
                            children: [
                              ListTile(
                                leading: const Icon(Icons.list),
                                title: const Text('All snippets'),
                                selected: _selectedFolderId == null,
                                onTap: () => Navigator.pop(context, (
                                  folderId: null,
                                  folderName: null,
                                )),
                              ),
                              for (final folder in folders)
                                ListTile(
                                  leading: const Icon(Icons.folder_outlined),
                                  title: Text(folder.name),
                                  selected: _selectedFolderId == folder.id,
                                  onTap: () => Navigator.pop(context, (
                                    folderId: folder.id,
                                    folderName: folder.name,
                                  )),
                                ),
                              if (folders.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  child: Text(
                                    'No folders yet. Create one to organize snippets.',
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

    if (selection == null || !mounted) {
      return;
    }

    setState(() {
      _selectedFolderId = selection.folderId;
      _selectedFolderName = selection.folderName;
    });
  }

  Future<void> _showCreateFolderDialog() async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final created = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Folder'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Folder name',
              hintText: 'Deploy',
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter a folder name';
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
        .read(snippetRepositoryProvider)
        .insertFolder(SnippetFoldersCompanion.insert(name: name));

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedFolderId = id;
      _selectedFolderName = name;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Created folder "$name"')));
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

/// Provider for snippets in the selected folder (null => all snippets).
final _snippetsProvider = FutureProvider.family<List<Snippet>, int?>((ref, id) {
  final repo = ref.watch(snippetRepositoryProvider);
  if (id == null) {
    return repo.getAll();
  }
  return repo.getByFolder(id);
});
