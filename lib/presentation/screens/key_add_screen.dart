import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/services/key_service.dart';

/// Screen for adding or importing SSH keys.
class KeyAddScreen extends ConsumerStatefulWidget {
  /// Creates a new [KeyAddScreen].
  const KeyAddScreen({super.key});

  @override
  ConsumerState<KeyAddScreen> createState() => _KeyAddScreenState();
}

class _KeyAddScreenState extends ConsumerState<KeyAddScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Add SSH Key'),
      bottom: TabBar(
        controller: _tabController,
        tabs: const [
          Tab(text: 'Generate'),
          Tab(text: 'Import'),
        ],
      ),
    ),
    body: TabBarView(
      controller: _tabController,
      children: const [_GenerateKeyTab(), _ImportKeyTab()],
    ),
  );
}

class _GenerateKeyTab extends ConsumerStatefulWidget {
  const _GenerateKeyTab();

  @override
  ConsumerState<_GenerateKeyTab> createState() => _GenerateKeyTabState();
}

class _GenerateKeyTabState extends ConsumerState<_GenerateKeyTab> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _passphraseController = TextEditingController();

  String _keyType = 'ed25519';
  int _rsaBits = 4096;
  bool _isGenerating = false;
  bool _showPassphrase = false;

  @override
  void dispose() {
    _nameController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _formKey,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Name
        TextFormField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: 'Key Name',
            hintText: 'My SSH Key',
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
        const SizedBox(height: 24),

        // Key type
        Text('Key Type', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'ed25519',
              label: Text('Ed25519'),
              icon: Icon(Icons.enhanced_encryption),
            ),
            ButtonSegment(
              value: 'rsa',
              label: Text('RSA'),
              icon: Icon(Icons.key),
            ),
          ],
          selected: {_keyType},
          onSelectionChanged: (value) {
            setState(() => _keyType = value.first);
          },
        ),
        const SizedBox(height: 16),

        // RSA bits (only shown for RSA)
        if (_keyType == 'rsa') ...[
          Text('RSA Key Size', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 2048, label: Text('2048')),
              ButtonSegment(value: 3072, label: Text('3072')),
              ButtonSegment(value: 4096, label: Text('4096')),
            ],
            selected: {_rsaBits},
            onSelectionChanged: (value) {
              setState(() => _rsaBits = value.first);
            },
          ),
          const SizedBox(height: 16),
        ],

        // Passphrase (optional)
        TextFormField(
          controller: _passphraseController,
          decoration: InputDecoration(
            labelText: 'Passphrase (optional)',
            hintText: 'Leave empty for no passphrase',
            prefixIcon: const Icon(Icons.lock),
            suffixIcon: IconButton(
              icon: Icon(
                _showPassphrase ? Icons.visibility_off : Icons.visibility,
              ),
              onPressed: () =>
                  setState(() => _showPassphrase = !_showPassphrase),
            ),
          ),
          obscureText: !_showPassphrase,
        ),
        const SizedBox(height: 8),
        Text(
          'A passphrase adds extra security. You will need to enter it each time you use this key.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        const SizedBox(height: 32),

        // Generate button
        FilledButton.icon(
          onPressed: _isGenerating ? null : _generateKey,
          icon: _isGenerating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add),
          label: Text(_isGenerating ? 'Generating...' : 'Generate Key'),
        ),

        if (_keyType == 'ed25519') ...[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Ed25519 is recommended for its security and performance.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );

  Future<void> _generateKey() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isGenerating = true);

    try {
      // Key generation requires external tools (ssh-keygen, pointycastle)
      // For now, show a message to import instead
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Key generation not yet implemented. Please use Import tab.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }
}

class _ImportKeyTab extends ConsumerStatefulWidget {
  const _ImportKeyTab();

  @override
  ConsumerState<_ImportKeyTab> createState() => _ImportKeyTabState();
}

class _ImportKeyTabState extends ConsumerState<_ImportKeyTab> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _privateKeyController = TextEditingController();
  final _passphraseController = TextEditingController();

  bool _isImporting = false;
  bool _showPassphrase = false;

  @override
  void dispose() {
    _nameController.dispose();
    _privateKeyController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _formKey,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Name
        TextFormField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: 'Key Name',
            hintText: 'Imported Key',
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

        // Private key content
        TextFormField(
          controller: _privateKeyController,
          decoration: const InputDecoration(
            labelText: 'Private Key (PEM format)',
            hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...',
            alignLabelWithHint: true,
          ),
          maxLines: 8,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          validator: (value) {
            if (value == null || value.isEmpty) {
              return 'Please enter the private key';
            }
            if (!value.contains('-----BEGIN') || !value.contains('-----END')) {
              return 'Invalid PEM format';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),

        // Passphrase (if encrypted)
        TextFormField(
          controller: _passphraseController,
          decoration: InputDecoration(
            labelText: 'Passphrase (if encrypted)',
            hintText: 'Leave empty if key is not encrypted',
            prefixIcon: const Icon(Icons.lock),
            suffixIcon: IconButton(
              icon: Icon(
                _showPassphrase ? Icons.visibility_off : Icons.visibility,
              ),
              onPressed: () =>
                  setState(() => _showPassphrase = !_showPassphrase),
            ),
          ),
          obscureText: !_showPassphrase,
        ),
        const SizedBox(height: 32),

        // Import button
        FilledButton.icon(
          onPressed: _isImporting ? null : _importKey,
          icon: _isImporting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download),
          label: Text(_isImporting ? 'Importing...' : 'Import Key'),
        ),
        const SizedBox(height: 16),

        // Import from file button
        OutlinedButton.icon(
          onPressed: _importFromFile,
          icon: const Icon(Icons.file_open),
          label: const Text('Import from File'),
        ),
      ],
    ),
  );

  Future<void> _importKey() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isImporting = true);

    try {
      final keyService = ref.read(keyServiceProvider);
      final passphrase = _passphraseController.text.isEmpty
          ? null
          : _passphraseController.text;

      final result = await keyService.importKey(
        name: _nameController.text,
        privateKeyPem: _privateKeyController.text,
        passphrase: passphrase,
      );

      if (result == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Invalid key format or incorrect passphrase'),
            ),
          );
        }
        return;
      }

      if (mounted) {
        context.pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Key imported successfully')),
        );
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error importing key: $e')));
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _importFromFile() async {
    // TODO: Implement file picker
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('File picker not yet implemented')),
    );
  }
}
