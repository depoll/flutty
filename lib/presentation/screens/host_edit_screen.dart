import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/port_forward_repository.dart';
import '../../data/repositories/snippet_repository.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/auto_connect_command.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/terminal_themes.dart';
import '../../domain/services/agent_launch_preset_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/secure_transfer_service.dart';
import '../../domain/services/ssh_service.dart';
import '../providers/entity_list_providers.dart';
import '../widgets/premium_access.dart';
import '../widgets/premium_badge.dart';
import '../widgets/terminal_text_style.dart';
import '../widgets/terminal_theme_picker.dart';
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
  late TextEditingController _tagsController;
  late TextEditingController _autoConnectCommandController;
  late TextEditingController _agentWorkingDirectoryController;
  late TextEditingController _agentTmuxSessionController;
  late TextEditingController _agentArgumentsController;

  int? _selectedKeyId;
  int? _selectedGroupId;
  int? _selectedJumpHostId;
  int? _selectedAutoConnectSnippetId;
  String? _selectedLightThemeId;
  String? _selectedDarkThemeId;
  String? _selectedFontFamily;
  AutoConnectCommandMode _selectedAutoConnectMode = AutoConnectCommandMode.none;
  AgentLaunchTool _selectedAgentLaunchTool = AgentLaunchTool.claudeCode;
  bool _useAgentLaunchPreset = false;
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
    _tagsController = TextEditingController();
    _autoConnectCommandController = TextEditingController();
    _agentWorkingDirectoryController = TextEditingController();
    _agentTmuxSessionController = TextEditingController();
    _agentArgumentsController = TextEditingController();

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
    final preset = await ref
        .read(agentLaunchPresetServiceProvider)
        .getPresetForHost(host.id);
    if (!mounted) return;
    setState(() {
      _existingHost = host;
      _labelController.text = host.label;
      _hostnameController.text = host.hostname;
      _portController.text = host.port.toString();
      _usernameController.text = host.username;
      _passwordController.text = host.password ?? '';
      _tagsController.text = host.tags ?? '';
      _selectedKeyId = host.keyId;
      _selectedGroupId = host.groupId;
      _selectedJumpHostId = host.jumpHostId;
      _selectedAutoConnectSnippetId = host.autoConnectSnippetId;
      _selectedLightThemeId = host.terminalThemeLightId;
      _selectedDarkThemeId = host.terminalThemeDarkId;
      _selectedFontFamily = host.terminalFontFamily;
      _autoConnectCommandController.text = host.autoConnectCommand ?? '';
      _selectedAutoConnectMode = resolveAutoConnectCommandMode(
        command: host.autoConnectCommand,
        snippetId: host.autoConnectSnippetId,
      );
      if (preset != null) {
        final presetCommand = buildAgentLaunchCommand(preset);
        _selectedAgentLaunchTool = preset.tool;
        _agentWorkingDirectoryController.text = preset.workingDirectory ?? '';
        _agentTmuxSessionController.text = preset.tmuxSessionName ?? '';
        _agentArgumentsController.text = preset.additionalArguments ?? '';
        _useAgentLaunchPreset = true;
        if (_selectedAutoConnectMode == AutoConnectCommandMode.custom ||
            host.autoConnectCommand == presetCommand) {
          _autoConnectCommandController.text = presetCommand;
        }
      }
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
    _tagsController.dispose();
    _autoConnectCommandController.dispose();
    _agentWorkingDirectoryController.dispose();
    _agentTmuxSessionController.dispose();
    _agentArgumentsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.hostId != null;
    final keysAsync = ref.watch(allKeysProvider);
    final hostsAsync = ref.watch(allHostsProvider);
    final snippetsAsync = ref.watch(_allSnippetsProvider);
    final monetizationState =
        ref.watch(monetizationStateProvider).asData?.value ??
        ref.read(monetizationServiceProvider).currentState;
    final hasAutomationAccess = monetizationState.allowsFeature(
      MonetizationFeature.autoConnectAutomation,
    );
    final hasAgentPresetAccess = monetizationState.allowsFeature(
      MonetizationFeature.agentLaunchPresets,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Host' : 'Add Host'),
        actions: [
          if (!isEditing)
            IconButton(
              icon: const Icon(Icons.download_for_offline_outlined),
              tooltip: 'Import transfer payload',
              onPressed: () => unawaited(_handleImportTransferTap()),
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
                    key: const Key('host-label-field'),
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
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _tagsController,
                    decoration: const InputDecoration(
                      labelText: 'Tags (optional)',
                      hintText: 'prod, db, eu-west',
                      prefixIcon: Icon(Icons.sell_outlined),
                      helperText:
                          'Comma-separated tags for search/organization',
                    ),
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
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
                          helperText:
                              'Auto tries up to 5 installed keys when password is empty',
                        ),
                        items: [
                          const DropdownMenuItem<int?>(child: Text('Auto')),
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
                    key: const Key('host-advanced-tile'),
                    title: const Text('Advanced'),
                    initiallyExpanded:
                        _selectedJumpHostId != null ||
                        _selectedAutoConnectMode != AutoConnectCommandMode.none,
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
                      Text(
                        'Auto-Run Command',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const PremiumBadge(),
                      if (!hasAutomationAccess) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _selectedAutoConnectMode ==
                                    AutoConnectCommandMode.none
                                ? 'MonkeySSH Pro unlocks auto-run commands, saved snippets, and guided agent launch presets.'
                                : 'This host keeps its saved Pro automation, but it will not run until MonkeySSH Pro is active again.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      DropdownButtonFormField<AutoConnectCommandMode>(
                        // ignore: deprecated_member_use
                        value: _selectedAutoConnectMode,
                        decoration: const InputDecoration(
                          labelText: 'After terminal connect',
                          prefixIcon: Icon(Icons.play_circle_outline),
                          helperText:
                              'Optional command to run after connecting or reconnecting.',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: AutoConnectCommandMode.none,
                            child: Text('Do nothing'),
                          ),
                          DropdownMenuItem(
                            value: AutoConnectCommandMode.custom,
                            child: Text('Run custom command'),
                          ),
                          DropdownMenuItem(
                            value: AutoConnectCommandMode.snippet,
                            child: Text('Run saved snippet'),
                          ),
                        ],
                        onChanged: (value) => value == null
                            ? null
                            : unawaited(_handleAutoConnectModeSelection(value)),
                      ),
                      if (_selectedAutoConnectMode ==
                          AutoConnectCommandMode.custom) ...[
                        const SizedBox(height: 16),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Use agent launch preset'),
                          subtitle: const Text(
                            'Build a repeatable startup flow for Claude Code, Copilot CLI, or Aider.',
                          ),
                          value: _useAgentLaunchPreset,
                          onChanged: hasAgentPresetAccess
                              ? (value) {
                                  setState(() => _useAgentLaunchPreset = value);
                                  if (value) {
                                    _syncAutoConnectCommandFromPreset();
                                  }
                                }
                              : null,
                        ),
                        if (_useAgentLaunchPreset) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Agent launch preset',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 12),
                          SegmentedButton<AgentLaunchTool>(
                            segments: AgentLaunchTool.values
                                .map(
                                  (tool) => ButtonSegment<AgentLaunchTool>(
                                    value: tool,
                                    label: Text(tool.label),
                                  ),
                                )
                                .toList(growable: false),
                            selected: {_selectedAgentLaunchTool},
                            onSelectionChanged: hasAgentPresetAccess
                                ? (selection) {
                                    setState(
                                      () => _selectedAgentLaunchTool =
                                          selection.first,
                                    );
                                    _syncAutoConnectCommandFromPreset();
                                  }
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _agentWorkingDirectoryController,
                            decoration: const InputDecoration(
                              labelText: 'Working directory (optional)',
                              hintText: '~/src/app',
                              prefixIcon: Icon(Icons.folder_outlined),
                            ),
                            onChanged: (_) =>
                                _syncAutoConnectCommandFromPreset(),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _agentTmuxSessionController,
                            decoration: const InputDecoration(
                              labelText: 'tmux session (optional)',
                              hintText: 'app-agent',
                              prefixIcon: Icon(Icons.view_carousel_outlined),
                            ),
                            onChanged: (_) =>
                                _syncAutoConnectCommandFromPreset(),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _agentArgumentsController,
                            decoration: const InputDecoration(
                              labelText: 'Extra arguments (optional)',
                              hintText: '--resume',
                              prefixIcon: Icon(Icons.tune_outlined),
                            ),
                            onChanged: (_) =>
                                _syncAutoConnectCommandFromPreset(),
                          ),
                          const SizedBox(height: 12),
                        ],
                        TextFormField(
                          key: const Key('host-auto-connect-command-field'),
                          controller: _autoConnectCommandController,
                          decoration: InputDecoration(
                            labelText: _useAgentLaunchPreset
                                ? 'Generated command'
                                : 'Custom command',
                            hintText: defaultAutoConnectCommandSuggestion,
                            helperText: _useAgentLaunchPreset
                                ? 'Turn off the preset builder to edit the raw command directly.'
                                : 'Suggested: tmux new -As MonkeySSH',
                            prefixIcon: const Icon(Icons.terminal),
                          ),
                          minLines: 1,
                          maxLines: 3,
                          readOnly: _useAgentLaunchPreset,
                          autocorrect: false,
                          validator: (value) {
                            if (_selectedAutoConnectMode !=
                                AutoConnectCommandMode.custom) {
                              return null;
                            }
                            if (value == null || value.trim().isEmpty) {
                              return 'Enter a command or choose "Do nothing"';
                            }
                            return null;
                          },
                        ),
                      ],
                      if (_selectedAutoConnectMode ==
                          AutoConnectCommandMode.snippet) ...[
                        const SizedBox(height: 16),
                        snippetsAsync.when(
                          loading: () => const LinearProgressIndicator(),
                          error: (_, _) => const Text('Error loading snippets'),
                          data: (snippets) {
                            final selectedSnippetStillExists = snippets.any(
                              (snippet) =>
                                  snippet.id == _selectedAutoConnectSnippetId,
                            );
                            final effectiveSnippetId =
                                selectedSnippetStillExists
                                ? _selectedAutoConnectSnippetId
                                : null;
                            final selectedSnippet = effectiveSnippetId == null
                                ? null
                                : snippets.firstWhere(
                                    (snippet) =>
                                        snippet.id == effectiveSnippetId,
                                  );
                            return Column(
                              children: [
                                DropdownButtonFormField<int?>(
                                  // ignore: deprecated_member_use
                                  value: effectiveSnippetId,
                                  decoration: const InputDecoration(
                                    labelText: 'Snippet',
                                    prefixIcon: Icon(Icons.code),
                                    helperText:
                                        'Variable prompts are not shown when a snippet runs automatically.',
                                  ),
                                  items: [
                                    const DropdownMenuItem<int?>(
                                      child: Text('Choose a snippet'),
                                    ),
                                    ...snippets.map(
                                      (snippet) => DropdownMenuItem<int?>(
                                        value: snippet.id,
                                        child: Text(snippet.name),
                                      ),
                                    ),
                                  ],
                                  onChanged: (value) => setState(
                                    () => _selectedAutoConnectSnippetId = value,
                                  ),
                                  validator: (value) {
                                    if (_selectedAutoConnectMode !=
                                        AutoConnectCommandMode.snippet) {
                                      return null;
                                    }
                                    if (value == null) {
                                      return 'Choose a snippet or select "Do nothing"';
                                    }
                                    return null;
                                  },
                                ),
                                if (selectedSnippet != null) ...[
                                  const SizedBox(height: 12),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      selectedSnippet.command,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(fontFamily: 'monospace'),
                                    ),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                      ],
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
                    key: const Key('host-save-button'),
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
      final presetService = ref.read(agentLaunchPresetServiceProvider);
      final port = int.parse(_portController.text);
      final password = _passwordController.text.isEmpty
          ? null
          : _passwordController.text;
      final tags = _tagsController.text.trim().isEmpty
          ? null
          : _tagsController.text.trim();
      final snippetRepo = ref.read(snippetRepositoryProvider);
      final autoConnectSnippetId =
          _selectedAutoConnectMode == AutoConnectCommandMode.snippet
          ? _selectedAutoConnectSnippetId
          : null;
      final selectedSnippet = autoConnectSnippetId == null
          ? null
          : await snippetRepo.getById(autoConnectSnippetId);
      final currentPreset = _buildCurrentAgentLaunchPreset();
      final presetCommand = currentPreset == null
          ? null
          : buildAgentLaunchCommand(currentPreset);
      final autoConnectCommand = switch (_selectedAutoConnectMode) {
        AutoConnectCommandMode.none => null,
        AutoConnectCommandMode.custom =>
          _useAgentLaunchPreset && presetCommand != null
              ? presetCommand
              : _autoConnectCommandController.text.trim(),
        AutoConnectCommandMode.snippet =>
          selectedSnippet?.command ?? _autoConnectCommandController.text,
      };
      final normalizedAutoConnectCommand =
          autoConnectCommand == null || autoConnectCommand.trim().isEmpty
          ? null
          : autoConnectCommand;
      final normalizedAutoConnectSnippetId =
          _selectedAutoConnectMode == AutoConnectCommandMode.snippet &&
              selectedSnippet != null
          ? selectedSnippet.id
          : null;
      final autoConnectRequiresConfirmation = _resolveAutoConnectConfirmation(
        command: normalizedAutoConnectCommand,
        snippetId: normalizedAutoConnectSnippetId,
      );
      var savedHostId = widget.hostId;

      if (widget.hostId != null && _existingHost != null) {
        // Update existing host
        final updatedHost = _existingHost!.copyWith(
          label: _labelController.text,
          hostname: _hostnameController.text,
          port: port,
          username: _usernameController.text,
          password: drift.Value(password),
          tags: drift.Value(tags),
          keyId: drift.Value(_selectedKeyId),
          groupId: drift.Value(_selectedGroupId),
          jumpHostId: drift.Value(_selectedJumpHostId),
          terminalThemeLightId: drift.Value(_selectedLightThemeId),
          terminalThemeDarkId: drift.Value(_selectedDarkThemeId),
          terminalFontFamily: drift.Value(_selectedFontFamily),
          autoConnectCommand: drift.Value(normalizedAutoConnectCommand),
          autoConnectSnippetId: drift.Value(normalizedAutoConnectSnippetId),
          autoConnectRequiresConfirmation: autoConnectRequiresConfirmation,
          isFavorite: _isFavorite,
        );
        await repo.update(updatedHost);
      } else {
        // Create new host
        savedHostId = await repo.insert(
          HostsCompanion.insert(
            label: _labelController.text,
            hostname: _hostnameController.text,
            port: drift.Value(port),
            username: _usernameController.text,
            password: drift.Value(password),
            tags: drift.Value(tags),
            keyId: drift.Value(_selectedKeyId),
            groupId: drift.Value(_selectedGroupId),
            jumpHostId: drift.Value(_selectedJumpHostId),
            terminalThemeLightId: drift.Value(_selectedLightThemeId),
            terminalThemeDarkId: drift.Value(_selectedDarkThemeId),
            terminalFontFamily: drift.Value(_selectedFontFamily),
            autoConnectCommand: drift.Value(normalizedAutoConnectCommand),
            autoConnectSnippetId: drift.Value(normalizedAutoConnectSnippetId),
            autoConnectRequiresConfirmation: drift.Value(
              autoConnectRequiresConfirmation,
            ),
            isFavorite: drift.Value(_isFavorite),
          ),
        );
      }

      if (savedHostId != null) {
        final preset = _buildCurrentAgentLaunchPreset();
        if (_selectedAutoConnectMode == AutoConnectCommandMode.custom &&
            _useAgentLaunchPreset &&
            preset != null) {
          await presetService.setPresetForHost(savedHostId, preset);
        } else {
          await presetService.deletePresetForHost(savedHostId);
        }
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

  Future<void> _handleAutoConnectModeSelection(
    AutoConnectCommandMode value,
  ) async {
    if (value != AutoConnectCommandMode.none) {
      final hasAccess = await requireMonetizationFeatureAccess(
        context: context,
        ref: ref,
        feature: MonetizationFeature.autoConnectAutomation,
      );
      if (!hasAccess || !mounted) {
        return;
      }
    }

    setState(() {
      _selectedAutoConnectMode = value;
      if (value != AutoConnectCommandMode.custom) {
        _useAgentLaunchPreset = false;
      }
    });
    if (_useAgentLaunchPreset) {
      _syncAutoConnectCommandFromPreset();
    }
  }

  bool _resolveAutoConnectConfirmation({
    required String? command,
    required int? snippetId,
  }) {
    final existingHost = _existingHost;
    if (existingHost == null || !existingHost.autoConnectRequiresConfirmation) {
      return false;
    }

    final previousMode = resolveAutoConnectCommandMode(
      command: existingHost.autoConnectCommand,
      snippetId: existingHost.autoConnectSnippetId,
    );
    final nextMode = resolveAutoConnectCommandMode(
      command: command,
      snippetId: snippetId,
    );
    if (nextMode != previousMode) {
      return false;
    }

    return switch (nextMode) {
      AutoConnectCommandMode.none => false,
      AutoConnectCommandMode.custom =>
        existingHost.autoConnectCommand == command,
      AutoConnectCommandMode.snippet =>
        existingHost.autoConnectSnippetId == snippetId,
    };
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;

    final messenger = ScaffoldMessenger.of(context)
      ..showSnackBar(const SnackBar(content: Text('Testing connection...')));

    try {
      final keyRepo = ref.read(keyRepositoryProvider);
      final sshService = ref.read(sshServiceProvider);

      SshKey? key;
      if (_selectedKeyId != null) {
        key = await keyRepo.getById(_selectedKeyId!);
      }

      SshConnectionConfig? jumpHostConfig;
      if (_selectedJumpHostId != null) {
        final jumpHost = await ref
            .read(hostRepositoryProvider)
            .getById(_selectedJumpHostId!);
        if (jumpHost != null) {
          SshKey? jumpKey;
          if (jumpHost.keyId != null) {
            jumpKey = await keyRepo.getById(jumpHost.keyId!);
          }
          jumpHostConfig = SshConnectionConfig.fromHost(jumpHost, key: jumpKey);
        }
      }

      final config = SshConnectionConfig(
        hostname: _hostnameController.text.trim(),
        port: int.parse(_portController.text),
        username: _usernameController.text.trim(),
        password: _passwordController.text.isEmpty
            ? null
            : _passwordController.text,
        privateKey: key?.privateKey,
        passphrase: key?.passphrase,
        jumpHost: jumpHostConfig,
      );

      final result = await sshService.connect(config);
      if (!mounted) {
        return;
      }

      if (!result.success || result.client == null) {
        messenger.showSnackBar(
          SnackBar(content: Text(result.error ?? 'Connection test failed')),
        );
        return;
      }

      await result.closeAll();
      messenger.showSnackBar(
        const SnackBar(content: Text('Connection successful')),
      );
    } on Exception catch (e) {
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text('Connection failed: $e')));
    }
  }

  Future<void> _handleImportTransferTap() async {
    final hasAccess = await requireMonetizationFeatureAccess(
      context: context,
      ref: ref,
      feature: MonetizationFeature.encryptedTransfers,
    );
    if (!hasAccess) {
      return;
    }
    await _importFromTransfer();
  }

  Future<void> _importFromTransfer() async {
    final encodedPayload = await pickTransferPayloadFromFile(context);
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

  AgentLaunchPreset? _buildCurrentAgentLaunchPreset() {
    if (!_useAgentLaunchPreset) {
      return null;
    }
    return AgentLaunchPreset(
      tool: _selectedAgentLaunchTool,
      workingDirectory: _agentWorkingDirectoryController.text.trim(),
      tmuxSessionName: _agentTmuxSessionController.text.trim(),
      additionalArguments: _agentArgumentsController.text.trim(),
    );
  }

  void _syncAutoConnectCommandFromPreset() {
    final preset = _buildCurrentAgentLaunchPreset();
    if (preset == null) {
      return;
    }
    _autoConnectCommandController.text = buildAgentLaunchCommand(preset);
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

TextStyle _getFontStyle(String family) =>
    resolveMonospaceTextStyle(family, fontSize: 14);

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

final _allSnippetsProvider = StreamProvider<List<Snippet>>((ref) {
  final repo = ref.watch(snippetRepositoryProvider);
  return repo.watchAll();
});
