/// Add / edit / remove flow for user-defined custom ACP providers.
///
/// A custom provider's exact launch command is privileged configuration: this
/// editor always shows the executable and every argument literally (never
/// shell-flattened) and requires an explicit review-and-approve confirmation
/// before the command is approved and saved. Command text is never logged.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../app/theme.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/services/acp_provider_service.dart';

/// Outcome of the custom provider editor.
@immutable
class AcpCustomProviderEditorResult {
  /// Creates an editor result.
  const AcpCustomProviderEditorResult({this.saved, this.removed = false});

  /// The provider that was saved, when the user completed the flow.
  final AcpCustomProviderDefinition? saved;

  /// Whether the provider was removed.
  final bool removed;
}

/// Opens the custom provider editor. Returns the outcome, or `null` when the
/// user dismissed it without saving or removing.
Future<AcpCustomProviderEditorResult?> showAcpCustomProviderEditor(
  BuildContext context, {
  required AcpProviderService providerService,
  AcpCustomProviderDefinition? existing,
}) => showModalBottomSheet<AcpCustomProviderEditorResult>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => _CustomProviderEditor(
    providerService: providerService,
    existing: existing,
  ),
);

class _CustomProviderEditor extends StatefulWidget {
  const _CustomProviderEditor({required this.providerService, this.existing});

  final AcpProviderService providerService;
  final AcpCustomProviderDefinition? existing;

  @override
  State<_CustomProviderEditor> createState() => _CustomProviderEditorState();
}

class _CustomProviderEditorState extends State<_CustomProviderEditor> {
  late final TextEditingController _label;
  late final TextEditingController _executable;
  late final List<TextEditingController> _arguments;
  String? _error;
  var _busy = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _label = TextEditingController(text: existing?.label ?? '');
    _executable = TextEditingController(
      text: existing?.launchCommand.executable ?? '',
    );
    _arguments = [
      for (final arg in existing?.launchCommand.arguments ?? const <String>[])
        TextEditingController(text: arg),
    ];
  }

  @override
  void dispose() {
    _label.dispose();
    _executable.dispose();
    for (final controller in _arguments) {
      controller.dispose();
    }
    super.dispose();
  }

  AcpLaunchCommand? _buildCommand() {
    final executable = _executable.text.trim();
    final arguments = [
      for (final controller in _arguments)
        if (controller.text.isNotEmpty) controller.text,
    ];
    try {
      final command = AcpLaunchCommand(
        executable: executable,
        arguments: arguments,
      );
      validateAcpLaunchCommand(command);
      return command;
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return null;
    }
  }

  Future<void> _review() async {
    setState(() => _error = null);
    final label = _label.text.trim();
    if (label.isEmpty) {
      setState(() => _error = 'Give this provider a name.');
      return;
    }
    final command = _buildCommand();
    if (command == null) {
      return;
    }
    AcpCustomProviderDefinition definition;
    try {
      if (_isEditing) {
        definition = widget.existing!
            .update(label: label, launchCommand: command)
            .approveCurrentCommand();
      } else {
        definition = AcpCustomProviderDefinition.create(
          id: const Uuid().v4(),
          label: label,
          launchCommand: command,
        );
      }
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }

    final approved = await _confirmCommand(definition);
    if (approved != true || !mounted) {
      return;
    }
    await _save(definition);
  }

  Future<bool?> _confirmCommand(AcpCustomProviderDefinition definition) {
    final colorScheme = Theme.of(context).colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review the exact command'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'This command runs on the remote host to launch the agent. '
                'Each part is passed literally — nothing is shell-parsed.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: FluttyTheme.spacingMd),
              _CommandReview(command: definition.launchCommand),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: colorScheme.primary),
            child: Text(_isEditing ? 'Approve and save' : 'Approve and add'),
          ),
        ],
      ),
    );
  }

  Future<void> _save(AcpCustomProviderDefinition definition) async {
    setState(() => _busy = true);
    try {
      await widget.providerService.saveCustomProvider(definition);
      if (!mounted) {
        return;
      }
      Navigator.of(
        context,
      ).pop(AcpCustomProviderEditorResult(saved: definition));
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = 'Could not save this provider. Try again.';
      });
    }
  }

  Future<void> _remove() async {
    final existing = widget.existing;
    if (existing == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${existing.label}?'),
        content: const Text(
          'This removes the saved provider. Live sessions are unaffected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.providerService.removeCustomProvider(existing.id);
      if (!mounted) {
        return;
      }
      Navigator.of(
        context,
      ).pop(const AcpCustomProviderEditorResult(removed: true));
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = 'Could not remove this provider. Try again.';
      });
    }
  }

  void _addArgument() {
    setState(() => _arguments.add(TextEditingController()));
  }

  void _removeArgument(int index) {
    setState(() {
      _arguments.removeAt(index).dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: FluttyTheme.spacingLg,
        right: FluttyTheme.spacingLg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + FluttyTheme.spacingLg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isEditing ? 'edit custom provider' : 'new custom provider',
              style: FluttyTheme.displayMono(
                fontSize: 18,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: FluttyTheme.spacingMd),
            TextField(
              controller: _label,
              enabled: !_busy,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. My agent',
              ),
            ),
            const SizedBox(height: FluttyTheme.spacingMd),
            TextField(
              controller: _executable,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              style: FluttyTheme.monoStyle,
              decoration: const InputDecoration(
                labelText: 'Executable',
                hintText: 'e.g. my-agent',
              ),
            ),
            const SizedBox(height: FluttyTheme.spacingMd),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Arguments',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            const SizedBox(height: FluttyTheme.spacingXs),
            for (var i = 0; i < _arguments.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: FluttyTheme.spacingSm),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _arguments[i],
                        enabled: !_busy,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: FluttyTheme.monoStyle,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: 'arg ${i + 1}',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove argument',
                      onPressed: _busy ? null : () => _removeArgument(i),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy ? null : _addArgument,
                icon: const Icon(Icons.add),
                label: const Text('Add argument'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: FluttyTheme.spacingSm),
              Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: colorScheme.error),
                  const SizedBox(width: FluttyTheme.spacingSm),
                  Expanded(
                    child: Text(
                      _error!,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: colorScheme.error),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: FluttyTheme.spacingLg),
            FilledButton.icon(
              onPressed: _busy ? null : _review,
              icon: const Icon(Icons.verified_outlined),
              label: Text(_isEditing ? 'Review and save' : 'Review and add'),
            ),
            if (_isEditing) ...[
              const SizedBox(height: FluttyTheme.spacingSm),
              TextButton.icon(
                onPressed: _busy ? null : _remove,
                icon: Icon(Icons.delete_outline, color: colorScheme.error),
                label: Text(
                  'Remove provider',
                  style: TextStyle(color: colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CommandReview extends StatelessWidget {
  const _CommandReview({required this.command});

  final AcpLaunchCommand command;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(FluttyTheme.spacingMd),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(FluttyTheme.radiusMd),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            command.executable,
            style: FluttyTheme.monoStyle.copyWith(color: colorScheme.onSurface),
          ),
          for (final arg in command.arguments)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: SelectableText(
                '  $arg',
                style: FluttyTheme.monoStyle.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
