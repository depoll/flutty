import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../domain/services/port_forward_runtime_service.dart';
import '../../domain/services/ssh_service.dart';

/// Result returned after saving a host-scoped port forward.
class HostPortForwardEditorResult {
  /// Creates a result with the user-facing save [message].
  const HostPortForwardEditorResult({required this.message});

  /// Message describing the persistence and live-activation outcome.
  final String message;
}

/// Opens the host-scoped port-forward editor used by Host Editor.
Future<HostPortForwardEditorResult?> showHostPortForwardEditorSheet({
  required BuildContext context,
  required int hostId,
  PortForward? existing,
  int? preferredConnectionId,
  bool? requestFocus,
}) => showModalBottomSheet<HostPortForwardEditorResult>(
  context: context,
  isScrollControlled: true,
  isDismissible: false,
  enableDrag: false,
  requestFocus: requestFocus,
  builder: (context) => _HostPortForwardEditorSheet(
    hostId: hostId,
    existing: existing,
    preferredConnectionId: preferredConnectionId,
  ),
);

class _HostPortForwardEditorSheet extends ConsumerStatefulWidget {
  const _HostPortForwardEditorSheet({
    required this.hostId,
    required this.existing,
    required this.preferredConnectionId,
  });

  final int hostId;
  final PortForward? existing;
  final int? preferredConnectionId;

  @override
  ConsumerState<_HostPortForwardEditorSheet> createState() =>
      _HostPortForwardEditorSheetState();
}

class _HostPortForwardEditorSheetState
    extends ConsumerState<_HostPortForwardEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _localHostController;
  late final TextEditingController _localPortController;
  late final TextEditingController _remoteHostController;
  late final TextEditingController _remotePortController;
  late bool _autoStart;
  late String _forwardType;
  bool _isSaving = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _localHostController = TextEditingController(
      text: existing?.localHost ?? '127.0.0.1',
    );
    _localPortController = TextEditingController(
      text: existing?.localPort.toString() ?? '',
    );
    _remoteHostController = TextEditingController(
      text: existing?.remoteHost ?? 'localhost',
    );
    _remotePortController = TextEditingController(
      text: existing?.remotePort.toString() ?? '',
    );
    _autoStart = existing?.autoStart ?? true;
    _forwardType = existing?.forwardType ?? 'local';
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
  Widget build(BuildContext context) => PopScope(
    canPop: !_isSaving,
    child: SafeArea(
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isEditing ? 'Edit Port Forward' : 'Add Port Forward',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _nameController,
                  enabled: !_isSaving,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'e.g., Database Tunnel',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => value == null || value.isEmpty
                      ? 'Name is required'
                      : null,
                ),
                const SizedBox(height: 16),
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
                  onSelectionChanged: _isSaving
                      ? null
                      : (selected) =>
                            setState(() => _forwardType = selected.first),
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
                const SizedBox(height: 20),
                Text('Local', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _localHostController,
                        enabled: !_isSaving,
                        decoration: const InputDecoration(
                          labelText: 'Host',
                          hintText: '127.0.0.1',
                          border: OutlineInputBorder(),
                        ),
                        validator: _validateRequired,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _localPortController,
                        enabled: !_isSaving,
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          hintText: '3306',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        validator: _validatePort,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Remote', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _remoteHostController,
                        enabled: !_isSaving,
                        decoration: const InputDecoration(
                          labelText: 'Host',
                          hintText: 'localhost',
                          border: OutlineInputBorder(),
                        ),
                        validator: _validateRequired,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _remotePortController,
                        enabled: !_isSaving,
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          hintText: '3306',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        validator: _validatePort,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SwitchListTile(
                  title: const Text('Auto-start'),
                  subtitle: const Text('Start this forward when connecting'),
                  value: _autoStart,
                  onChanged: _isSaving
                      ? null
                      : (value) => setState(() => _autoStart = value),
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _isSaving
                          ? null
                          : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: _isSaving ? null : _save,
                      child: _isSaving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_isEditing ? 'Save' : 'Add'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  String? _validatePort(String? value) {
    if (value == null || value.isEmpty) {
      return 'Required';
    }
    final port = int.tryParse(value);
    if (port == null || port < 1 || port > 65535) {
      return 'Invalid port (1-65535)';
    }
    return null;
  }

  String? _validateRequired(String? value) =>
      value == null || value.isEmpty ? 'Required' : null;

  bool _isLoopbackBindAddress(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1' ||
        normalized.startsWith('127.');
  }

  Future<bool> _confirmNonLoopbackLocalBind() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Expose port forward?'),
        content: Text(
          'Binding to ${_localHostController.text.trim()} may make this '
          'forward reachable from other devices on your local network.',
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

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    if (_forwardType == 'local' &&
        !_isLoopbackBindAddress(_localHostController.text)) {
      final confirmed = await _confirmNonLoopbackLocalBind();
      if (!confirmed || !mounted) {
        return;
      }
    }
    final name = _nameController.text;
    final localHost = _localHostController.text;
    final localPort = int.parse(_localPortController.text);
    final remoteHost = _remoteHostController.text;
    final remotePort = int.parse(_remotePortController.text);
    final autoStart = _autoStart;
    final forwardType = _forwardType;
    final previous = widget.existing;
    final repository = ref.read(portForwardRepositoryProvider);
    final sessions = ref.read(activeSessionsProvider.notifier);
    setState(() => _isSaving = true);

    try {
      late final PortForward savedPortForward;
      if (previous != null) {
        savedPortForward = previous.copyWith(
          name: name,
          forwardType: forwardType,
          localHost: localHost,
          localPort: localPort,
          remoteHost: remoteHost,
          remotePort: remotePort,
          autoStart: autoStart,
        );
        await repository.update(savedPortForward);
      } else {
        final portForwardId = await repository.insert(
          PortForwardsCompanion.insert(
            hostId: widget.hostId,
            name: name,
            forwardType: forwardType,
            localHost: drift.Value(localHost),
            localPort: localPort,
            remoteHost: remoteHost,
            remotePort: remotePort,
            autoStart: drift.Value(autoStart),
          ),
        );
        savedPortForward = PortForward(
          id: portForwardId,
          name: name,
          hostId: widget.hostId,
          forwardType: forwardType,
          localHost: localHost,
          localPort: localPort,
          remoteHost: remoteHost,
          remotePort: remotePort,
          autoStart: autoStart,
          createdAt: DateTime.now(),
        );
      }

      PortForwardActivationResult? activationResult;
      if (shouldApplyPortForwardLive(
        sessions: sessions,
        portForward: savedPortForward,
        previous: previous,
      )) {
        try {
          activationResult = await activatePortForwardOnConnectedSession(
            sessions: sessions,
            portForward: savedPortForward,
            previous: previous,
            preferredConnectionId: widget.preferredConnectionId,
          );
        } on Exception catch (error, stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'port forwards',
              context: ErrorDescription(
                'while applying a host port forward live',
              ),
            ),
          );
          activationResult = const PortForwardActivationResult(
            status: PortForwardActivationStatus.failed,
          );
        }
      }

      if (mounted) {
        Navigator.pop(
          context,
          HostPortForwardEditorResult(
            message: _saveResultMessage(activationResult),
          ),
        );
      }
    } on Exception catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'port forwards',
          context: ErrorDescription('while saving a host port forward'),
        ),
      );
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save port forward. Try again.'),
          ),
        );
      }
    }
  }

  String _saveResultMessage(PortForwardActivationResult? activationResult) {
    switch (activationResult?.status) {
      case PortForwardActivationStatus.started:
        return _isEditing
            ? 'Port forward updated and applied live'
            : 'Port forward added and started';
      case PortForwardActivationStatus.failed:
        return 'Port forward saved, but it couldn’t start. '
            'Check the configured ports.';
      case PortForwardActivationStatus.alreadyActive:
      case PortForwardActivationStatus.noConnectedSession:
      case null:
        return _isEditing ? 'Port forward updated' : 'Port forward added';
    }
  }
}
