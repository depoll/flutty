import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import 'hosts_screen.dart';

/// Screen for adding or editing a host.
class HostEditScreen extends ConsumerStatefulWidget {
  /// Creates a new [HostEditScreen].
  const HostEditScreen({this.hostId, super.key});

  /// The host ID to edit, or null for a new host.
  final int? hostId;

  @override
  ConsumerState<HostEditScreen> createState() => _HostEditScreenState();
}

class _HostEditScreenState extends ConsumerState<HostEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _labelController;
  late TextEditingController _hostnameController;
  late TextEditingController _portController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;

  int? _selectedKeyId;
  int? _selectedGroupId;
  int? _selectedJumpHostId;
  bool _isFavorite = false;
  bool _isLoading = false;
  bool _showPassword = false;

  Host? _existingHost;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController();
    _hostnameController = TextEditingController();
    _portController = TextEditingController(text: '22');
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();

    if (widget.hostId != null) {
      _loadHost();
    }
  }

  Future<void> _loadHost() async {
    setState(() => _isLoading = true);
    final host = await ref.read(hostRepositoryProvider).getById(widget.hostId!);
    if (host != null && mounted) {
      setState(() {
        _existingHost = host;
        _labelController.text = host.label;
        _hostnameController.text = host.hostname;
        _portController.text = host.port.toString();
        _usernameController.text = host.username;
        _passwordController.text = host.password ?? '';
        _selectedKeyId = host.keyId;
        _selectedGroupId = host.groupId;
        _selectedJumpHostId = host.jumpHostId;
        _isFavorite = host.isFavorite;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _labelController.dispose();
    _hostnameController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.hostId != null;
    final keysAsync = ref.watch(_allKeysProvider);
    final hostsAsync = ref.watch(allHostsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Host' : 'Add Host'),
        actions: [
          IconButton(
            icon: Icon(_isFavorite ? Icons.star : Icons.star_border),
            onPressed: () => setState(() => _isFavorite = !_isFavorite),
            tooltip: _isFavorite ? 'Remove from favorites' : 'Add to favorites',
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
                  // Label
                  TextFormField(
                    controller: _labelController,
                    decoration: const InputDecoration(
                      labelText: 'Label',
                      hintText: 'My Server',
                      prefixIcon: Icon(Icons.label),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter a label';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Hostname
                  TextFormField(
                    controller: _hostnameController,
                    decoration: const InputDecoration(
                      labelText: 'Hostname',
                      hintText: 'example.com or 192.168.1.1',
                      prefixIcon: Icon(Icons.dns),
                    ),
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter a hostname';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Port
                  TextFormField(
                    controller: _portController,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      hintText: '22',
                      prefixIcon: Icon(Icons.numbers),
                    ),
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter a port';
                      }
                      final port = int.tryParse(value);
                      if (port == null || port < 1 || port > 65535) {
                        return 'Port must be between 1 and 65535';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Username
                  TextFormField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      hintText: 'root',
                      prefixIcon: Icon(Icons.person),
                    ),
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please enter a username';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),

                  // Authentication section
                  Text(
                    'Authentication',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),

                  // Password
                  TextFormField(
                    controller: _passwordController,
                    decoration: InputDecoration(
                      labelText: 'Password (optional)',
                      hintText: 'Leave empty for key-only auth',
                      prefixIcon: const Icon(Icons.lock),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () =>
                            setState(() => _showPassword = !_showPassword),
                      ),
                    ),
                    obscureText: !_showPassword,
                    textInputAction: TextInputAction.done,
                  ),
                  const SizedBox(height: 16),

                  // SSH Key dropdown
                  keysAsync.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (_, _) => const Text('Error loading keys'),
                    data: (keys) => DropdownButtonFormField<int?>(
                      value: _selectedKeyId,
                      decoration: const InputDecoration(
                        labelText: 'SSH Key (optional)',
                        prefixIcon: Icon(Icons.key),
                      ),
                      items: [
                        const DropdownMenuItem(child: Text('None')),
                        ...keys.map(
                          (key) => DropdownMenuItem(
                            value: key.id,
                            child: Text(key.name),
                          ),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _selectedKeyId = value),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Advanced section
                  ExpansionTile(
                    title: const Text('Advanced'),
                    initiallyExpanded: _selectedJumpHostId != null,
                    children: [
                      const SizedBox(height: 8),
                      // Jump host dropdown
                      hostsAsync.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (_, _) => const Text('Error loading hosts'),
                        data: (hosts) {
                          // Filter out current host from jump host options
                          final availableHosts = hosts
                              .where((h) => h.id != widget.hostId)
                              .toList();
                          return DropdownButtonFormField<int?>(
                            initialValue: _selectedJumpHostId,
                            decoration: const InputDecoration(
                              labelText: 'Jump Host (optional)',
                              prefixIcon: Icon(Icons.hub),
                              helperText:
                                  'Connect through another host (bastion)',
                            ),
                            items: [
                              const DropdownMenuItem(child: Text('None')),
                              ...availableHosts.map(
                                (host) => DropdownMenuItem(
                                  value: host.id,
                                  child: Text(host.label),
                                ),
                              ),
                            ],
                            onChanged: (value) =>
                                setState(() => _selectedJumpHostId = value),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                  const SizedBox(height: 32),

                  // Save button
                  FilledButton.icon(
                    onPressed: _saveHost,
                    icon: const Icon(Icons.save),
                    label: Text(isEditing ? 'Save Changes' : 'Add Host'),
                  ),
                  const SizedBox(height: 16),

                  // Test connection button
                  OutlinedButton.icon(
                    onPressed: _testConnection,
                    icon: const Icon(Icons.network_check),
                    label: const Text('Test Connection'),
                  ),
                ],
              ),
            ),
    );
  }

  Future<void> _saveHost() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final repo = ref.read(hostRepositoryProvider);
      final port = int.parse(_portController.text);
      final password = _passwordController.text.isEmpty
          ? null
          : _passwordController.text;

      if (widget.hostId != null && _existingHost != null) {
        // Update existing host
        await repo.update(
          _existingHost!.copyWith(
            label: _labelController.text,
            hostname: _hostnameController.text,
            port: port,
            username: _usernameController.text,
            password: drift.Value(password),
            keyId: drift.Value(_selectedKeyId),
            groupId: drift.Value(_selectedGroupId),
            jumpHostId: drift.Value(_selectedJumpHostId),
            isFavorite: _isFavorite,
          ),
        );
      } else {
        // Create new host
        await repo.insert(
          HostsCompanion.insert(
            label: _labelController.text,
            hostname: _hostnameController.text,
            port: drift.Value(port),
            username: _usernameController.text,
            password: drift.Value(password),
            keyId: drift.Value(_selectedKeyId),
            groupId: drift.Value(_selectedGroupId),
            jumpHostId: drift.Value(_selectedJumpHostId),
            isFavorite: drift.Value(_isFavorite),
          ),
        );
      }

      ref.invalidate(allHostsProvider);

      if (mounted) {
        context.pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.hostId != null ? 'Host updated' : 'Host added',
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

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Testing connection...')));

    // TODO: Implement connection test
    await Future<void>.delayed(const Duration(seconds: 1));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connection test not yet implemented')),
      );
    }
  }
}

/// Provider for all SSH keys as stream.
final _allKeysProvider = StreamProvider<List<SshKey>>((ref) {
  final repo = ref.watch(keyRepositoryProvider);
  return repo.watchAll();
});
