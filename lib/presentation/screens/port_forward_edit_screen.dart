import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../domain/models/host_kind.dart';
import '../../domain/services/port_forward_browser_service.dart';
import '../../domain/services/port_forward_runtime_service.dart';
import '../../domain/services/ssh_service.dart';
import '../widgets/unsaved_changes_guard.dart';

typedef _PortForwardEditDraft = ({
  String name,
  String localHost,
  String localPort,
  String remoteHost,
  String remotePort,
  bool autoStart,
  String forwardType,
  int? selectedHostId,
});

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
  _PortForwardEditDraft? _initialDraft;

  @override
  void initState() {
    super.initState();
    _loadHosts();
    if (widget.portForwardId != null) {
      _loadPortForward();
    } else {
      _initialDraft = _currentDraft();
    }
  }

  Future<void> _loadHosts() async {
    final hosts = await ref.read(hostRepositoryProvider).getAll();
    if (!mounted) {
      return;
    }
    final sshHosts = hosts.where((host) => !isLocalTerminalHost(host)).toList();
    setState(() {
      _hosts = sshHosts;
      if (_selectedHostId != null &&
          !sshHosts.any((host) => host.id == _selectedHostId)) {
        _selectedHostId = null;
      }
    });
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
        _initialDraft = _currentDraft();
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

  Future<bool> _confirmNonLoopbackBind({
    required String host,
    required bool isRemote,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isRemote ? 'Expose remote port forward?' : 'Expose port forward?',
        ),
        content: Text(
          isRemote
              ? 'Binding the remote listener to $host may make this forward '
                    'reachable from other devices that can access the SSH host.'
              : 'Binding to $host may make this forward reachable from other '
                    'devices on your local network.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.portForwardId != null;

    return UnsavedChangesGuard(
      hasUnsavedChanges: _hasUnsavedChanges,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isEditing ? 'Edit Port Forward' : 'Add Port Forward'),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Form(
                key: _formKey,
                onChanged: () => setState(() {}),
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
                    Text(
                      'Local',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
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
                    Text(
                      'Remote',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
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
      ),
    );
  }

  bool get _hasUnsavedChanges {
    final initialDraft = _initialDraft;
    return initialDraft != null && _currentDraft() != initialDraft;
  }

  _PortForwardEditDraft _currentDraft() => (
    name: _nameController.text,
    localHost: _localHostController.text,
    localPort: _localPortController.text,
    remoteHost: _remoteHostController.text,
    remotePort: _remotePortController.text,
    autoStart: _autoStart,
    forwardType: _forwardType,
    selectedHostId: _selectedHostId,
  );

  void _closeWithoutUnsavedPrompt(SnackBar snackBar) {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _initialDraft = _currentDraft();
      _isLoading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      context.pop();
      messenger.showSnackBar(snackBar);
    });
  }

  Future<void> _savePortForward() async {
    if (!_formKey.currentState!.validate()) return;
    final selectedHostId = _selectedHostId;
    if (selectedHostId == null) {
      return;
    }
    final selectedHost = _hosts.cast<Host?>().firstWhere(
      (host) => host?.id == selectedHostId,
      orElse: () => null,
    );
    if (selectedHost == null || isLocalTerminalHost(selectedHost)) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Port forwards require an SSH host.')),
      );
      return;
    }
    final isRemote = _forwardType == 'remote';
    final bindHost = isRemote
        ? _remoteHostController.text.trim()
        : _localHostController.text.trim();
    if (!isPortForwardLoopbackHost(bindHost)) {
      final confirmed = await _confirmNonLoopbackBind(
        host: bindHost,
        isRemote: isRemote,
      );
      if (!confirmed || !mounted) return;
    }

    setState(() => _isLoading = true);
    var didScheduleClose = false;

    try {
      final repo = ref.read(portForwardRepositoryProvider);
      final previousPortForward = _existingPortForward;
      late final PortForward savedPortForward;

      if (widget.portForwardId != null && previousPortForward != null) {
        // Update existing port forward
        savedPortForward = previousPortForward.copyWith(
          name: _nameController.text,
          hostId: selectedHostId,
          forwardType: _forwardType,
          localHost: _localHostController.text,
          localPort: int.parse(_localPortController.text),
          remoteHost: _remoteHostController.text,
          remotePort: int.parse(_remotePortController.text),
          autoStart: _autoStart,
        );
        await repo.update(savedPortForward);
      } else {
        // Create new port forward
        final portForwardId = await repo.insert(
          PortForwardsCompanion.insert(
            name: _nameController.text,
            hostId: selectedHostId,
            forwardType: _forwardType,
            localHost: drift.Value(_localHostController.text),
            localPort: int.parse(_localPortController.text),
            remoteHost: _remoteHostController.text,
            remotePort: int.parse(_remotePortController.text),
            autoStart: drift.Value(_autoStart),
          ),
        );
        savedPortForward = PortForward(
          id: portForwardId,
          name: _nameController.text,
          hostId: selectedHostId,
          forwardType: _forwardType,
          localHost: _localHostController.text,
          localPort: int.parse(_localPortController.text),
          remoteHost: _remoteHostController.text,
          remotePort: int.parse(_remotePortController.text),
          autoStart: _autoStart,
          createdAt: DateTime.now(),
        );
      }

      PortForwardActivationResult? activationResult;
      final sessions = ref.read(activeSessionsProvider.notifier);
      if (shouldApplyPortForwardLive(
        sessions: sessions,
        portForward: savedPortForward,
        previous: previousPortForward,
      )) {
        try {
          activationResult = await activatePortForwardOnConnectedSession(
            sessions: sessions,
            portForward: savedPortForward,
            previous: previousPortForward,
          );
        } on Exception catch (error, stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'port forwards',
              context: ErrorDescription(
                'while applying a saved port forward live',
              ),
            ),
          );
          activationResult = const PortForwardActivationResult(
            status: PortForwardActivationStatus.failed,
          );
        }
      }

      if (mounted) {
        didScheduleClose = true;
        _closeWithoutUnsavedPrompt(
          SnackBar(content: Text(_saveResultMessage(activationResult))),
        );
      }
    } on Exception catch (e) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          library: 'port forwards',
          context: ErrorDescription('while saving a port forward'),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save port forward. Try again.'),
          ),
        );
      }
    } finally {
      if (mounted && !didScheduleClose) setState(() => _isLoading = false);
    }
  }

  String _saveResultMessage(PortForwardActivationResult? activationResult) {
    final isEditing = widget.portForwardId != null;
    switch (activationResult?.status) {
      case PortForwardActivationStatus.started:
        return isEditing
            ? 'Port forward updated and applied live'
            : 'Port forward added and started';
      case PortForwardActivationStatus.failed:
        return 'Port forward saved, but it couldn’t start. '
            'Check the configured ports.';
      case PortForwardActivationStatus.alreadyActive:
      case PortForwardActivationStatus.noConnectedSession:
      case PortForwardActivationStatus.superseded:
      case null:
        return isEditing ? 'Port forward updated' : 'Port forward added';
    }
  }
}
