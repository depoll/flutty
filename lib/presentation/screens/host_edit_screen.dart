import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/secure_transfer_service.dart';
import '../widgets/terminal_theme_picker.dart';
import 'hosts_screen.dart';
import 'transfer_screen.dart';

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
  String? _selectedLightThemeId;
  String? _selectedDarkThemeId;
  String? _selectedFontFamily;
  bool _isFavorite = false;
  bool _isLoading = false;
  bool _showPassword = false;

  Host? _existingHost;
  List<PortForward> _portForwards = [];

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
    if (!mounted) return;
    if (host == null) {
      setState(() => _isLoading = false);
      return;
    }
    final portForwards = await ref
        .read(portForwardRepositoryProvider)
        .getByHostId(host.id);
    if (!mounted) return;
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
      _selectedLightThemeId = host.terminalThemeLightId;
      _selectedDarkThemeId = host.terminalThemeDarkId;
      _selectedFontFamily = host.terminalFontFamily;
      _isFavorite = host.isFavorite;
      _portForwards = portForwards;
      _isLoading = false;
    });
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
          if (!isEditing)
            IconButton(
              icon: const Icon(Icons.download_for_offline_outlined),
              tooltip: 'Import transfer payload',
              onPressed: _importFromTransfer,
            ),
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
                    data: (keys) {
                      // Validate selected key still exists
                      final validKeyId =
                          _selectedKeyId != null &&
                              keys.any((k) => k.id == _selectedKeyId)
                          ? _selectedKeyId
                          : null;
                      if (validKeyId != _selectedKeyId) {
                        // Schedule state update for next frame
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) setState(() => _selectedKeyId = null);
                        });
                      }
                      return DropdownButtonFormField<int?>(
                        // ignore: deprecated_member_use
                        value: validKeyId,
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
                      );
                    },
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
                          // Validate selected jump host still exists
                          final validJumpHostId =
                              _selectedJumpHostId != null &&
                                  availableHosts.any(
                                    (h) => h.id == _selectedJumpHostId,
                                  )
                              ? _selectedJumpHostId
                              : null;
                          if (validJumpHostId != _selectedJumpHostId) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                setState(() => _selectedJumpHostId = null);
                              }
                            });
                          }
                          return DropdownButtonFormField<int?>(
                            // ignore: deprecated_member_use
                            value: validJumpHostId,
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
                      const SizedBox(height: 24),
                      // Terminal theme section
                      Text(
                        'Terminal Theme',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Light mode theme
                      _ThemeSelectionTile(
                        label: 'Light Mode Theme',
                        themeId: _selectedLightThemeId,
                        defaultLabel: 'Use default',
                        onTap: () => _selectTheme(isLight: true),
                      ),
                      const SizedBox(height: 8),
                      // Dark mode theme
                      _ThemeSelectionTile(
                        label: 'Dark Mode Theme',
                        themeId: _selectedDarkThemeId,
                        defaultLabel: 'Use default',
                        onTap: () => _selectTheme(isLight: false),
                      ),
                      const SizedBox(height: 16),
                      // Terminal font section
                      _FontSelectionTile(
                        fontFamily: _selectedFontFamily,
                        defaultLabel: 'Use default',
                        onTap: _selectFont,
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                  const SizedBox(height: 32),

                  // Port Forwards section
                  _buildPortForwardsSection(context, isEditing),
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
            terminalThemeLightId: drift.Value(_selectedLightThemeId),
            terminalThemeDarkId: drift.Value(_selectedDarkThemeId),
            terminalFontFamily: drift.Value(_selectedFontFamily),
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
            terminalThemeLightId: drift.Value(_selectedLightThemeId),
            terminalThemeDarkId: drift.Value(_selectedDarkThemeId),
            terminalFontFamily: drift.Value(_selectedFontFamily),
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

  Future<void> _importFromTransfer() async {
    final source = await showTransferImportSourceSheet(context);
    if (!mounted || source == null) {
      return;
    }

    String? encodedPayload;
    if (source == TransferImportSource.qr) {
      encodedPayload = await scanTransferPayload(context);
    } else {
      encodedPayload = await pickTransferPayloadFromFile(context);
    }
    if (!mounted || encodedPayload == null) {
      return;
    }

    final transferPassphrase = await showTransferPassphraseDialog(
      context: context,
      title: 'Host transfer passphrase',
    );
    if (!mounted || transferPassphrase == null) {
      return;
    }

    try {
      final transferService = ref.read(secureTransferServiceProvider);
      final payload = await transferService.decryptPayload(
        encodedPayload: encodedPayload,
        transferPassphrase: transferPassphrase,
      );
      if (payload.type != TransferPayloadType.host) {
        throw const FormatException(
          'This transfer payload does not contain a host',
        );
      }

      final importedHost = await transferService.importHostPayload(payload);
      ref.invalidate(allHostsProvider);
      if (!mounted) {
        return;
      }
      context.pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported host: ${importedHost.label}')),
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: ${error.message}')),
      );
    } on Exception catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $error')));
    }
  }

  Future<void> _selectTheme({required bool isLight}) async {
    final currentId = isLight ? _selectedLightThemeId : _selectedDarkThemeId;
    final theme = await showThemePickerDialog(
      context: context,
      currentThemeId: currentId,
    );
    if (theme != null && mounted) {
      setState(() {
        if (isLight) {
          _selectedLightThemeId = theme.id;
        } else {
          _selectedDarkThemeId = theme.id;
        }
      });
    }
  }

  Future<void> _selectFont() async {
    final selected = await showFontPickerDialog(
      context: context,
      currentFontFamily: _selectedFontFamily,
    );
    if (selected != null && mounted) {
      setState(() {
        _selectedFontFamily = selected;
      });
    }
  }

  Widget _buildPortForwardsSection(BuildContext context, bool isEditing) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.swap_horiz_rounded,
              size: 20,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              'Port Forwards',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (isEditing)
              TextButton.icon(
                onPressed: () => _showAddEditPortForwardDialog(null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (!isEditing)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Save the host first to add port forwards.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (_portForwards.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.swap_horiz,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No port forwards configured.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.outline.withAlpha(80)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: _portForwards.asMap().entries.map((entry) {
                final index = entry.key;
                final pf = entry.value;
                final isLast = index == _portForwards.length - 1;

                return Column(
                  children: [
                    _PortForwardTile(
                      portForward: pf,
                      onEdit: () => _showAddEditPortForwardDialog(pf),
                      onDelete: () => _deletePortForward(pf),
                    ),
                    if (!isLast)
                      Divider(
                        height: 1,
                        color: colorScheme.outline.withAlpha(40),
                      ),
                  ],
                );
              }).toList(),
            ),
          ),
      ],
    );
  }

  Future<void> _showAddEditPortForwardDialog(PortForward? existing) async {
    final isEdit = existing != null;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final localPortController = TextEditingController(
      text: existing?.localPort.toString() ?? '',
    );
    final remoteHostController = TextEditingController(
      text: existing?.remoteHost ?? 'localhost',
    );
    final remotePortController = TextEditingController(
      text: existing?.remotePort.toString() ?? '',
    );

    var autoStart = existing?.autoStart ?? true;

    final formKey = GlobalKey<FormState>();

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isEdit ? 'Edit Port Forward' : 'Add Port Forward',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'e.g., Database Tunnel',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      v == null || v.isEmpty ? 'Name is required' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: localPortController,
                  decoration: const InputDecoration(
                    labelText: 'Local Port',
                    hintText: 'e.g., 3306',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Required';
                    final port = int.tryParse(v);
                    if (port == null || port < 1 || port > 65535) {
                      return 'Invalid port (1-65535)';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: remoteHostController,
                        decoration: const InputDecoration(
                          labelText: 'Remote Host',
                          hintText: 'localhost',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => v == null || v.isEmpty
                            ? 'Remote host is required'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: remotePortController,
                        decoration: const InputDecoration(
                          labelText: 'Remote Port',
                          hintText: '3306',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v == null || v.isEmpty) return 'Required';
                          final port = int.tryParse(v);
                          if (port == null || port < 1 || port > 65535) {
                            return 'Invalid';
                          }
                          return null;
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SwitchListTile(
                  title: const Text('Auto-start'),
                  subtitle: const Text('Start this forward when connecting'),
                  value: autoStart,
                  onChanged: (value) => setModalState(() => autoStart = value),
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () {
                        if (formKey.currentState!.validate()) {
                          Navigator.pop(context, true);
                        }
                      },
                      child: Text(isEdit ? 'Save' : 'Add'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if ((result ?? false) && mounted) {
      final repo = ref.read(portForwardRepositoryProvider);

      if (isEdit) {
        await repo.update(
          existing.copyWith(
            name: nameController.text,
            localPort: int.parse(localPortController.text),
            remoteHost: remoteHostController.text,
            remotePort: int.parse(remotePortController.text),
            autoStart: autoStart,
          ),
        );
      } else {
        await repo.insert(
          PortForwardsCompanion.insert(
            hostId: widget.hostId!,
            name: nameController.text,
            forwardType: 'local',
            localPort: int.parse(localPortController.text),
            remoteHost: remoteHostController.text,
            remotePort: int.parse(remotePortController.text),
            autoStart: drift.Value(autoStart),
          ),
        );
      }

      // Reload port forwards
      final updated = await repo.getByHostId(widget.hostId!);
      setState(() => _portForwards = updated);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isEdit ? 'Port forward updated' : 'Port forward added',
            ),
          ),
        );
      }
    }

    nameController.dispose();
    localPortController.dispose();
    remoteHostController.dispose();
    remotePortController.dispose();
  }

  Future<void> _deletePortForward(PortForward pf) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Port Forward'),
        content: Text('Are you sure you want to delete "${pf.name}"?'),
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

    if ((confirmed ?? false) && mounted) {
      final repo = ref.read(portForwardRepositoryProvider);
      await repo.delete(pf.id);

      // Reload port forwards
      final updated = await repo.getByHostId(widget.hostId!);
      setState(() => _portForwards = updated);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted "${pf.name}"')));
      }
    }
  }
}

class _ThemeSelectionTile extends StatelessWidget {
  const _ThemeSelectionTile({
    required this.label,
    required this.themeId,
    required this.defaultLabel,
    required this.onTap,
  });

  final String label;
  final String? themeId;
  final String defaultLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = themeId != null ? TerminalThemes.getById(themeId!) : null;
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme?.background ?? colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outline),
        ),
        child: theme != null
            ? Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _colorDot(theme.red),
                    _colorDot(theme.green),
                    _colorDot(theme.blue),
                  ],
                ),
              )
            : Icon(
                Icons.palette_outlined,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
      ),
      title: Text(label),
      subtitle: Text(theme?.name ?? defaultLabel),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (themeId != null)
            IconButton(
              icon: const Icon(Icons.clear, size: 18),
              onPressed: () {
                // Clear theme selection - handled via callback
              },
              tooltip: 'Reset to default',
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _colorDot(Color color) => Container(
    width: 6,
    height: 6,
    margin: const EdgeInsets.symmetric(horizontal: 1),
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _FontSelectionTile extends StatelessWidget {
  const _FontSelectionTile({
    required this.fontFamily,
    required this.defaultLabel,
    required this.onTap,
  });

  final String? fontFamily;
  final String defaultLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final displayName = fontFamily ?? defaultLabel;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outline),
        ),
        child: Icon(
          Icons.font_download_outlined,
          size: 20,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      title: const Text('Terminal Font'),
      subtitle: Text(displayName),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fontFamily != null)
            IconButton(
              icon: const Icon(Icons.clear, size: 18),
              onPressed: () {
                // Clear font selection - handled via callback
              },
              tooltip: 'Reset to default',
            ),
          const Icon(Icons.chevron_right),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Shows a font picker dialog and returns the selected font family.
Future<String?> showFontPickerDialog({
  required BuildContext context,
  required String? currentFontFamily,
}) async {
  const options = [
    'monospace',
    'JetBrains Mono',
    'Fira Code',
    'Source Code Pro',
    'Ubuntu Mono',
    'Roboto Mono',
    'IBM Plex Mono',
    'Inconsolata',
    'Anonymous Pro',
    'Cousine',
    'PT Mono',
    'Space Mono',
    'VT323',
    'Share Tech Mono',
    'Overpass Mono',
    'Oxygen Mono',
  ];
  const previewText = 'AaBbCc 0123 {}[]';

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Terminal Font'),
      content: SizedBox(
        width: double.maxFinite,
        height: 450,
        child: Column(
          children: [
            // Current selection preview
            if (currentFontFamily != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withAlpha(50),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary.withAlpha(100),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Currently Selected',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          Text(
                            currentFontFamily,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            previewText,
                            style: _getFontStyle(currentFontFamily),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            // Font list
            Expanded(
              child: ListView.builder(
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final family = options[index];
                  final isSelected = family == currentFontFamily;
                  return ListTile(
                    title: Text(family),
                    subtitle: Text(previewText, style: _getFontStyle(family)),
                    selected: isSelected,
                    trailing: isSelected ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.pop(context, family),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

TextStyle _getFontStyle(String family) {
  switch (family) {
    case 'JetBrains Mono':
      return GoogleFonts.jetBrainsMono(fontSize: 14);
    case 'Fira Code':
      return GoogleFonts.firaCode(fontSize: 14);
    case 'Source Code Pro':
      return GoogleFonts.sourceCodePro(fontSize: 14);
    case 'Ubuntu Mono':
      return GoogleFonts.ubuntuMono(fontSize: 14);
    case 'Roboto Mono':
      return GoogleFonts.robotoMono(fontSize: 14);
    case 'IBM Plex Mono':
      return GoogleFonts.ibmPlexMono(fontSize: 14);
    case 'Inconsolata':
      return GoogleFonts.inconsolata(fontSize: 14);
    case 'Anonymous Pro':
      return GoogleFonts.anonymousPro(fontSize: 14);
    case 'Cousine':
      return GoogleFonts.cousine(fontSize: 14);
    case 'PT Mono':
      return GoogleFonts.ptMono(fontSize: 14);
    case 'Space Mono':
      return GoogleFonts.spaceMono(fontSize: 14);
    case 'VT323':
      return GoogleFonts.vt323(fontSize: 14);
    case 'Share Tech Mono':
      return GoogleFonts.shareTechMono(fontSize: 14);
    case 'Overpass Mono':
      return GoogleFonts.overpassMono(fontSize: 14);
    case 'Oxygen Mono':
      return GoogleFonts.oxygenMono(fontSize: 14);
    default:
      return const TextStyle(fontFamily: 'monospace', fontSize: 14);
  }
}

/// A tile displaying a single port forward with edit/delete actions.
class _PortForwardTile extends StatelessWidget {
  const _PortForwardTile({
    required this.portForward,
    required this.onEdit,
    required this.onDelete,
  });

  /// The port forward to display.
  final PortForward portForward;

  /// Called when the edit button is tapped.
  final VoidCallback onEdit;

  /// Called when the delete button is tapped.
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.swap_horiz,
          color: colorScheme.onPrimaryContainer,
          size: 20,
        ),
      ),
      title: Text(
        portForward.name,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        '${portForward.localPort} → '
        '${portForward.remoteHost}:${portForward.remotePort}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
          fontFamily: 'monospace',
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            onPressed: onEdit,
            tooltip: 'Edit',
          ),
          IconButton(
            icon: Icon(
              Icons.delete_outline,
              size: 20,
              color: colorScheme.error,
            ),
            onPressed: onDelete,
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }
}

/// Provider for all SSH keys as stream.
final _allKeysProvider = StreamProvider<List<SshKey>>((ref) {
  final repo = ref.watch(keyRepositoryProvider);
  return repo.watchAll();
});
