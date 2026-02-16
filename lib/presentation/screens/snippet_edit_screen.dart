import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/snippet_repository.dart';

/// Screen for adding or editing a snippet.
class SnippetEditScreen extends ConsumerStatefulWidget {
  /// Creates a new [SnippetEditScreen].
  const SnippetEditScreen({this.snippetId, super.key});

  /// The snippet ID to edit, or null for a new snippet.
  final int? snippetId;

  @override
  ConsumerState<SnippetEditScreen> createState() => _SnippetEditScreenState();
}

class _SnippetEditScreenState extends ConsumerState<SnippetEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _contentController = TextEditingController();
  final _descriptionController = TextEditingController();

  bool _isLoading = false;
  Snippet? _existingSnippet;
  int? _selectedFolderId;
  List<SnippetFolder> _folders = [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadFolders());
    if (widget.snippetId != null) {
      unawaited(_loadSnippet());
    }
  }

  Future<void> _loadFolders() async {
    final folders = await ref.read(snippetRepositoryProvider).getAllFolders();
    if (mounted) {
      setState(() => _folders = folders);
    }
  }

  Future<void> _loadSnippet() async {
    setState(() => _isLoading = true);
    final snippet = await ref
        .read(snippetRepositoryProvider)
        .getById(widget.snippetId!);
    if (snippet != null && mounted) {
      setState(() {
        _existingSnippet = snippet;
        _nameController.text = snippet.name;
        _contentController.text = snippet.command;
        _descriptionController.text = snippet.description ?? '';
        _selectedFolderId = snippet.folderId;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _contentController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.snippetId != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Snippet' : 'Add Snippet'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: _showVariablesHelp,
            tooltip: 'Variable syntax',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Name
                  TextFormField(
                    controller: _nameController,
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

                  // Description (optional)
                  TextFormField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                      hintText: 'What this snippet does',
                      prefixIcon: Icon(Icons.description),
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),

                  DropdownButtonFormField<int?>(
                    initialValue: _selectedFolderId,
                    decoration: const InputDecoration(
                      labelText: 'Folder (optional)',
                      prefixIcon: Icon(Icons.folder_outlined),
                    ),
                    items: [
                      const DropdownMenuItem<int?>(child: Text('No folder')),
                      ..._folders.map(
                        (folder) => DropdownMenuItem<int?>(
                          value: folder.id,
                          child: Text(folder.name),
                        ),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _selectedFolderId = value),
                  ),
                  const SizedBox(height: 16),

                  // Content
                  TextFormField(
                    controller: _contentController,
                    decoration: const InputDecoration(
                      labelText: 'Command',
                      hintText: 'docker restart {{container}}',
                      alignLabelWithHint: true,
                    ),
                    maxLines: 6,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
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

                  // Variable preview
                  _buildVariablePreview(),
                  const SizedBox(height: 32),

                  // Save button
                  FilledButton.icon(
                    onPressed: _saveSnippet,
                    icon: const Icon(Icons.save),
                    label: Text(isEditing ? 'Save Changes' : 'Add Snippet'),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildVariablePreview() {
    final content = _contentController.text;
    final variables = _extractVariables(content);

    if (variables.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Variables', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: variables
                  .map(
                    (v) => Chip(
                      label: Text(v),
                      visualDensity: VisualDensity.compact,
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _extractVariables(String content) {
    final regex = RegExp(r'\{\{(\w+)\}\}');
    final matches = regex.allMatches(content);
    return matches.map((m) => m.group(1)!).toSet().toList();
  }

  Future<void> _saveSnippet() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final repo = ref.read(snippetRepositoryProvider);
      final description = _descriptionController.text.isEmpty
          ? null
          : _descriptionController.text;

      if (widget.snippetId != null && _existingSnippet != null) {
        // Update existing snippet
        await repo.update(
          _existingSnippet!.copyWith(
            name: _nameController.text,
            command: _contentController.text,
            description: drift.Value(description),
            folderId: drift.Value(_selectedFolderId),
          ),
        );
      } else {
        // Create new snippet
        await repo.insert(
          SnippetsCompanion.insert(
            name: _nameController.text,
            command: _contentController.text,
            description: drift.Value(description),
            folderId: drift.Value(_selectedFolderId),
          ),
        );
      }

      if (mounted) {
        context.pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.snippetId != null ? 'Snippet updated' : 'Snippet added',
            ),
          ),
        );
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showVariablesHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Variable Substitution'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Use {{variable}} syntax to create placeholders.'),
              SizedBox(height: 16),
              Text('Examples:', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text('• ssh {{user}}@{{host}}'),
              Text('• docker exec -it {{container}} bash'),
              Text('• git push origin {{branch}}'),
              SizedBox(height: 16),
              Text('When executing, you\'ll be prompted to fill in values.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}
