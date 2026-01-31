import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';

/// Screen for adding or editing a port forward rule.
class PortForwardEditScreen extends ConsumerStatefulWidget {
  /// Creates a new [PortForwardEditScreen].
  const PortForwardEditScreen({this.portForwardId, super.key});

  /// The port forward ID to edit, or null for a new port forward.
  final int? portForwardId;

  @override
  ConsumerState<PortForwardEditScreen> createState() =>
      _PortForwardEditScreenState();
}

class _PortForwardEditScreenState extends ConsumerState<PortForwardEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _localHostController = TextEditingController(text: '127.0.0.1');
  final _localPortController = TextEditingController();
  final _remoteHostController = TextEditingController();
  final _remotePortController = TextEditingController();

  bool _isLoading = false;
  bool _autoStart = false;
  String _forwardType = 'local';
  int? _selectedHostId;
  PortForward? _existingPortForward;
  List<Host> _hosts = [];

  @override
  void initState() {
    super.initState();
    _loadHosts();
    if (widget.portForwardId != null) {
      _loadPortForward();
    }
  }

  Future<void> _loadHosts() async {
    final hosts = await ref.read(hostRepositoryProvider).getAll();
    if (mounted) {
      setState(() => _hosts = hosts);
    }
  }

  Future<void> _loadPortForward() async {
    setState(() => _isLoading = true);
    final portForward = await ref
        .read(portForwardRepositoryProvider)
        .getById(widget.portForwardId!);
    if (portForward != null && mounted) {
      setState(() {
        _existingPortForward = portForward;
        _nameController.text = portForward.name;
        _selectedHostId = portForward.hostId;
        _forwardType = portForward.forwardType;
        _localHostController.text = portForward.localHost;
        _localPortController.text = portForward.localPort.toString();
        _remoteHostController.text = portForward.remoteHost;
        _remotePortController.text = portForward.remotePort.toString();
        _autoStart = portForward.autoStart;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _localHostController.dispose();
    _localPortController.dispose();
    _remoteHostController.dispose();
    _remotePortController.dispose();
    super.dispose();
  }

  String? _validatePort(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter a port';
    }
    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) {
      return 'Port must be between 1 and 65535';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.portForwardId != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Port Forward' : 'Add Port Forward'),
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
                      hintText: 'Web Server',
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

                  // Host selection
                  DropdownButtonFormField<int>(
                    initialValue: _selectedHostId,
                    decoration: const InputDecoration(
                      labelText: 'Host',
                      prefixIcon: Icon(Icons.computer),
                    ),
                    items: _hosts
                        .map(
                          (host) => DropdownMenuItem(
                            value: host.id,
                            child: Text(host.label),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _selectedHostId = value),
                    validator: (value) {
                      if (value == null) {
                        return 'Please select a host';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Forward type
                  Text(
                    'Forward Type',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'local',
                        label: Text('Local'),
                        icon: Icon(Icons.arrow_forward),
                      ),
                      ButtonSegment(
                        value: 'remote',
                        label: Text('Remote'),
                        icon: Icon(Icons.arrow_back),
                      ),
                    ],
                    selected: {_forwardType},
                    onSelectionChanged: (selected) {
                      setState(() => _forwardType = selected.first);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _forwardType == 'local'
                        ? 'Forward local port to remote host'
                        : 'Forward remote port to local host',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Local host/port
                  Text('Local', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _localHostController,
                          decoration: const InputDecoration(
                            labelText: 'Host',
                            hintText: '127.0.0.1',
                          ),
                          textInputAction: TextInputAction.next,
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Required';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextFormField(
                          controller: _localPortController,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            hintText: '8080',
                          ),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          textInputAction: TextInputAction.next,
                          validator: _validatePort,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Remote host/port
                  Text('Remote', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _remoteHostController,
                          decoration: const InputDecoration(
                            labelText: 'Host',
                            hintText: 'localhost',
                          ),
                          textInputAction: TextInputAction.next,
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Required';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextFormField(
                          controller: _remotePortController,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            hintText: '80',
                          ),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          textInputAction: TextInputAction.done,
                          validator: _validatePort,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Auto-start toggle
                  SwitchListTile(
                    title: const Text('Auto-start'),
                    subtitle: const Text(
                      'Start forwarding when connecting to host',
                    ),
                    value: _autoStart,
                    onChanged: (value) => setState(() => _autoStart = value),
                  ),
                  const SizedBox(height: 32),

                  // Save button
                  FilledButton.icon(
                    onPressed: _savePortForward,
                    icon: const Icon(Icons.save),
                    label: Text(
                      isEditing ? 'Save Changes' : 'Add Port Forward',
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Future<void> _savePortForward() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final repo = ref.read(portForwardRepositoryProvider);

      if (widget.portForwardId != null && _existingPortForward != null) {
        // Update existing port forward
        await repo.update(
          _existingPortForward!.copyWith(
            name: _nameController.text,
            hostId: _selectedHostId,
            forwardType: _forwardType,
            localHost: _localHostController.text,
            localPort: int.parse(_localPortController.text),
            remoteHost: _remoteHostController.text,
            remotePort: int.parse(_remotePortController.text),
            autoStart: _autoStart,
          ),
        );
      } else {
        // Create new port forward
        await repo.insert(
          PortForwardsCompanion.insert(
            name: _nameController.text,
            hostId: _selectedHostId!,
            forwardType: _forwardType,
            localHost: drift.Value(_localHostController.text),
            localPort: int.parse(_localPortController.text),
            remoteHost: _remoteHostController.text,
            remotePort: int.parse(_remotePortController.text),
            autoStart: drift.Value(_autoStart),
          ),
        );
      }

      if (mounted) {
        context.pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.portForwardId != null
                  ? 'Port forward updated'
                  : 'Port forward added',
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
}
