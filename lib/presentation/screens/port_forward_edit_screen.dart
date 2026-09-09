import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../domain/services/port_forward_browser_service.dart';
import '../../domain/services/port_forward_runtime_service.dart';
import '../../domain/services/ssh_service.dart';
import '../widgets/port_forward_fields.dart';
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
  String? _loadError;
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
    if (mounted) {
      setState(() => _hosts = hosts);
    }
  }

  Future<void> _loadPortForward() async {
    setState(() => _isLoading = true);
    try {
      final portForward = await ref
          .read(portForwardRepositoryProvider)
          .getById(widget.portForwardId!);
      if (!mounted) return;
      if (portForward == null) {
        _loadError = 'Port forward not found.';
        return;
      }
      _existingPortForward = portForward;
      _nameController.text = portForward.name;
      _selectedHostId = portForward.hostId;
      _forwardType = portForward.forwardType;
      _localHostController.text = portForward.localHost;
      _localPortController.text = portForward.localPort.toString();
      _remoteHostController.text = portForward.remoteHost;
      _remotePortController.text = portForward.remotePort.toString();
      _autoStart = portForward.autoStart;
      _initialDraft = _currentDraft();
    } on Object {
      if (mounted) _loadError = 'Could not load port forward. Try again.';
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
            : _loadError != null
            ? Center(child: Text(_loadError!))
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

                    PortForwardTypeField(
                      value: _forwardType,
                      onChanged: (value) =>
                          setState(() => _forwardType = value),
                    ),
                    const SizedBox(height: 24),
                    PortForwardEndpointFields(
                      label: 'Local',
                      hostController: _localHostController,
                      portController: _localPortController,
                      hostHint: '127.0.0.1',
                      portHint: '8080',
                    ),
                    const SizedBox(height: 24),
                    PortForwardEndpointFields(
                      label: 'Remote',
                      hostController: _remoteHostController,
                      portController: _remotePortController,
                      hostHint: 'localhost',
                      portHint: '80',
                      portInputAction: TextInputAction.done,
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
    final isRemote = _forwardType == 'remote';
    final bindHost = isRemote
        ? _remoteHostController.text.trim()
        : _localHostController.text.trim();
    if (!isPortForwardLoopbackHost(bindHost)) {
      final confirmed = await confirmPortForwardExposure(
        context: context,
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
          hostId: _selectedHostId,
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
            hostId: _selectedHostId!,
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
          hostId: _selectedHostId!,
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
