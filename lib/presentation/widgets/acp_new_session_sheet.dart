/// Staged new-session flow for launching an ACP coding-agent session.
///
/// Walks the user through: choose a saved host → connect/reuse SSH → choose a
/// built-in or custom provider → choose a working directory → start a new
/// session or reconnect a recent one. It handles helper-install confirmation,
/// missing/auth-required providers (with a safe Open Terminal escape hatch),
/// custom provider management, and the free-tier concurrency choice.
///
/// No prompts, transcripts, or command text are ever logged.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/models/acp_provider.dart';
import '../../domain/models/acp_recent_session.dart';
import '../../domain/models/acp_session_keys.dart';
import '../../domain/models/acp_session_state.dart';
import '../../domain/models/agent_launch_preset.dart';
import '../../domain/models/monetization.dart';
import '../../domain/models/remote_multiplexer.dart';
import '../../domain/services/acp_concurrency_policy.dart';
import '../../domain/services/acp_provider_service.dart';
import '../../domain/services/acp_session_manager.dart';
import '../../domain/services/agent_launch_preset_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/monkeymux_installer_service.dart';
import '../../domain/services/ssh_service.dart';
import '../providers/entity_list_providers.dart';
import 'acp_concurrency_choice.dart';
import 'acp_config_option_controls.dart';
import 'acp_connection_support.dart';
import 'acp_custom_provider_editor.dart';
import 'acp_session_presentation.dart';

/// Opens the staged new-session sheet, returning the launched session key when
/// a session starts (so the caller can open its chat), or `null` otherwise.
Future<AcpSessionKey?> showAcpNewSessionSheet(
  BuildContext context, {
  int? initialHostId,
  String? initialProviderId,
}) => showModalBottomSheet<AcpSessionKey>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => _NewSessionSheet(
    initialHostId: initialHostId,
    initialProviderId: initialProviderId,
  ),
);

/// Returns the terminal-auth command for [providerId], if the provider is a
/// built-in that advertises one.
AcpLaunchCommand? acpTerminalAuthCommandFor(String providerId) {
  for (final provider in acpBuiltinProviders) {
    if (provider.id == providerId) {
      return provider.terminalAuthCommand;
    }
  }
  return null;
}

/// Defaults resolved for the ACP start-or-resume sheet.
@immutable
final class AcpSessionLaunchDefaults {
  /// Creates resolved launch defaults.
  const AcpSessionLaunchDefaults({
    required this.hostId,
    required this.providerId,
    required this.cwd,
  });

  /// Initially selected saved host.
  final int? hostId;

  /// Initially selected ACP provider.
  final String? providerId;

  /// Initially selected remote working directory.
  final String cwd;
}

/// Maps a saved terminal-agent tool to an available ACP provider.
String? acpProviderIdForAgentLaunchTool(
  AgentLaunchTool tool,
  List<AcpProvider> providers,
) {
  for (final provider in providers) {
    if (agentLaunchToolForCommandName(provider.launchCommand.executable) ==
        tool) {
      return provider.id;
    }
  }
  return null;
}

/// Resolves launch defaults from explicit inputs, active/recent sessions, and
/// the host's saved agent/MonkeyMux configuration.
AcpSessionLaunchDefaults resolveAcpSessionLaunchDefaults({
  required List<Host> hosts,
  required List<AcpProvider> providers,
  required List<AcpRecentSessionRef> recents,
  required Set<int> activeHostIds,
  required Map<int, AgentLaunchPreset> presets,
  AcpSessionKey? lastSelected,
  int? initialHostId,
  String? initialProviderId,
}) {
  Host? hostForId(int? id) =>
      id == null ? null : hosts.where((host) => host.id == id).firstOrNull;

  final lastSelectedHost = hostForId(lastSelected?.hostId);
  final activeHosts = hosts
      .where((host) => activeHostIds.contains(host.id))
      .toList(growable: false);
  final configuredHost = hosts.firstWhereOrNull((host) {
    if (presets.containsKey(host.id)) {
      return true;
    }
    return RemoteMuxBackendPresentation.fromStorageValue(
          host.remoteMuxBackend,
        ) ==
        RemoteMuxBackend.monkeyMux;
  });
  final recentHost = recents
      .map((recent) => hostForId(recent.hostId))
      .whereType<Host>()
      .firstOrNull;
  final host =
      hostForId(initialHostId) ??
      (lastSelectedHost != null && activeHostIds.contains(lastSelectedHost.id)
          ? lastSelectedHost
          : null) ??
      (activeHosts.length == 1 ? activeHosts.single : null) ??
      lastSelectedHost ??
      activeHosts.firstOrNull ??
      configuredHost ??
      recentHost ??
      hosts.firstOrNull;

  final availableProviderIds = providers.map((provider) => provider.id).toSet();
  final preset = host == null ? null : presets[host.id];
  final matchingRecents = host == null
      ? const <AcpRecentSessionRef>[]
      : recents.where((recent) => recent.hostId == host.id).toList();
  final recentProviderId = matchingRecents
      .map((recent) => recent.providerId)
      .firstWhereOrNull(availableProviderIds.contains);
  final lastSelectedProviderId =
      host != null &&
          lastSelected?.hostId == host.id &&
          availableProviderIds.contains(lastSelected?.providerId)
      ? lastSelected!.providerId
      : null;
  final providerId =
      (availableProviderIds.contains(initialProviderId)
          ? initialProviderId
          : null) ??
      (preset == null
          ? null
          : acpProviderIdForAgentLaunchTool(preset.tool, providers)) ??
      lastSelectedProviderId ??
      recentProviderId ??
      (availableProviderIds.contains(AcpBuiltinProviderIds.copilotCli)
          ? AcpBuiltinProviderIds.copilotCli
          : providers.firstOrNull?.id);

  String? nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  final matchingRecent = matchingRecents.firstWhereOrNull(
    (recent) => recent.providerId == providerId,
  );
  final cwd =
      nonEmpty(preset?.workingDirectory) ??
      nonEmpty(host?.tmuxWorkingDirectory) ??
      nonEmpty(matchingRecent?.cwd) ??
      '~';
  return AcpSessionLaunchDefaults(
    hostId: host?.id,
    providerId: providerId,
    cwd: cwd,
  );
}

class _NewSessionSheet extends ConsumerStatefulWidget {
  const _NewSessionSheet({this.initialHostId, this.initialProviderId});

  final int? initialHostId;
  final String? initialProviderId;

  @override
  ConsumerState<_NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends ConsumerState<_NewSessionSheet> {
  int? _hostId;
  String? _providerId;
  final TextEditingController _cwd = TextEditingController();
  bool _cwdEdited = false;
  AcpRecentSessionRef? _selectedRecent;
  var _busy = false;
  var _loadingDefaults = true;
  var _defaultsScheduled = false;
  var _hostDefaultsGeneration = 0;
  String? _error;
  late final Future<List<AcpRecentSessionRef>> _recents;

  // Set once a session has started: the sheet stays open on an initial
  // configuration stage until the user explicitly opens the chat.
  AcpSessionKey? _configuringKey;

  @override
  void initState() {
    super.initState();
    _hostId = widget.initialHostId;
    _providerId = widget.initialProviderId;
    _recents = ref.read(acpSessionManagerProvider).loadRecentSessions();
  }

  @override
  void dispose() {
    _cwd.dispose();
    super.dispose();
  }

  void _scheduleDefaults(List<Host> hosts, List<AcpProvider> providers) {
    if (_defaultsScheduled) {
      return;
    }
    _defaultsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_loadDefaults(hosts, providers));
      }
    });
  }

  Future<void> _loadDefaults(
    List<Host> hosts,
    List<AcpProvider> providers,
  ) async {
    try {
      final manager = ref.read(acpSessionManagerProvider);
      final presetService = ref.read(agentLaunchPresetServiceProvider);
      final recents = await _recents;
      final lastSelected = await manager.loadLastSelected();
      final presetEntries = await Future.wait(
        hosts.map(
          (host) async =>
              MapEntry(host.id, await presetService.getPresetForHost(host.id)),
        ),
      );
      final presets = <int, AgentLaunchPreset>{
        for (final entry in presetEntries)
          if (entry.value != null) entry.key: entry.value!,
      };
      final activeHostIds = ref
          .read(sshServiceProvider)
          .allSessions
          .map((session) => session.hostId)
          .toSet();
      final defaults = resolveAcpSessionLaunchDefaults(
        hosts: hosts,
        providers: providers,
        recents: recents,
        activeHostIds: activeHostIds,
        presets: presets,
        lastSelected: lastSelected,
        initialHostId: widget.initialHostId,
        initialProviderId: widget.initialProviderId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _hostId = defaults.hostId;
        _providerId = defaults.providerId;
        if (!_cwdEdited) {
          _cwd.text = defaults.cwd;
        }
        _loadingDefaults = false;
      });
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'acp.launch',
        'defaults_failed',
        fields: {'errorType': error.runtimeType},
      );
      if (!mounted) {
        return;
      }
      final defaults = resolveAcpSessionLaunchDefaults(
        hosts: hosts,
        providers: providers,
        recents: const [],
        activeHostIds: const {},
        presets: const {},
        initialHostId: widget.initialHostId,
        initialProviderId: widget.initialProviderId,
      );
      setState(() {
        _hostId = defaults.hostId;
        _providerId = defaults.providerId;
        if (!_cwdEdited) {
          _cwd.text = defaults.cwd;
        }
        _loadingDefaults = false;
      });
    }
  }

  Future<void> _selectHost(
    int? hostId,
    List<Host> hosts,
    List<AcpProvider> providers,
  ) async {
    final generation = ++_hostDefaultsGeneration;
    setState(() {
      _hostId = hostId;
      _cwdEdited = false;
      _selectedRecent = null;
      _loadingDefaults = hostId != null;
    });
    final host = hosts.where((candidate) => candidate.id == hostId).firstOrNull;
    if (host == null) {
      setState(() => _loadingDefaults = false);
      return;
    }
    try {
      final preset = await ref
          .read(agentLaunchPresetServiceProvider)
          .getPresetForHost(host.id);
      final defaults = resolveAcpSessionLaunchDefaults(
        hosts: [host],
        providers: providers,
        recents: await _recents,
        activeHostIds: const {},
        presets: preset == null ? const {} : {host.id: preset},
        initialHostId: host.id,
      );
      if (!mounted ||
          generation != _hostDefaultsGeneration ||
          _hostId != host.id) {
        return;
      }
      setState(() {
        _providerId = defaults.providerId;
        if (!_cwdEdited) {
          _cwd.text = defaults.cwd;
        }
        _loadingDefaults = false;
      });
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'acp.launch',
        'host_defaults_failed',
        fields: {'hostId': host.id, 'errorType': error.runtimeType},
      );
      if (mounted &&
          generation == _hostDefaultsGeneration &&
          _hostId == host.id) {
        final configuredCwd = host.tmuxWorkingDirectory?.trim();
        setState(() {
          if (!_cwdEdited) {
            _cwd.text = configuredCwd != null && configuredCwd.isNotEmpty
                ? configuredCwd
                : '~';
          }
          _loadingDefaults = false;
        });
      }
    }
  }

  Future<bool> _confirmInstall(MonkeyMuxInstallRequest request) =>
      confirmAcpMonkeyMuxInstall(context, request);

  Future<void> _openTerminalForAuth(String providerId) async {
    final hostId = _hostId;
    if (hostId == null) {
      return;
    }
    final authCommand = acpTerminalAuthCommandFor(providerId);
    final navigator = Navigator.of(context);
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (authCommand != null) {
      await Clipboard.setData(ClipboardData(text: authCommand.argv.join(' ')));
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Sign-in command copied — run it in the terminal.'),
        ),
      );
    }
    navigator.pop();
    router.go(buildTmuxAlertHomeLocationSafe());
    unawaited(router.push<void>('/terminal/$hostId'));
  }

  Future<AcpSessionLaunchResult?> _launch({
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
  }) async {
    final hostId = _hostId;
    final providerId = _providerId;
    if (hostId == null || providerId == null) {
      return null;
    }
    final manager = ref.read(acpSessionManagerProvider);
    final cwd = _cwd.text.trim().isEmpty ? '~' : _cwd.text.trim();

    final knownHost = ref
        .read(allHostsProvider)
        .asData
        ?.value
        .where((host) => host.id == hostId)
        .firstOrNull;
    final connection = await ensureAcpHostConnection(
      context,
      ref,
      hostId,
      knownHost: knownHost,
    );
    if (!mounted) {
      return null;
    }
    if (!connection.success) {
      setState(
        () => _error =
            connection.error ?? 'Could not establish the SSH connection.',
      );
      return null;
    }

    final recent = _selectedRecent;
    if (recent != null) {
      return manager.reconnectSession(
        hostId: recent.hostId,
        providerId: recent.providerId,
        bridgeId: recent.bridgeId,
        acpSessionId: recent.acpSessionId,
        cwd: recent.cwd ?? cwd,
        confirmInstall: _confirmInstall,
        replace: replace,
      );
    }
    return manager.startNewSession(
      hostId: hostId,
      providerId: providerId,
      cwd: cwd,
      confirmInstall: _confirmInstall,
      replace: replace,
    );
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var result = await _launch();
      // Resolve a free-tier concurrency block, then retry once.
      if (result is AcpSessionLaunchBlocked && mounted) {
        final resolved = await _resolveConcurrency(result.decision);
        if (resolved == null) {
          setState(() => _busy = false);
          return;
        }
        result = resolved;
      }
      if (!mounted) {
        return;
      }
      switch (result) {
        case AcpSessionLaunchStarted(:final key):
          // Keep the sheet open on the initial configuration stage; the user
          // adjusts settings and then explicitly opens the chat.
          setState(() {
            _busy = false;
            _configuringKey = key;
          });
        case AcpSessionLaunchFailed(:final error):
          await _handleFailure(error);
          if (mounted) {
            setState(() => _busy = false);
          }
        case AcpSessionLaunchBlocked():
        case null:
          setState(() => _busy = false);
      }
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not start the session. Try again.';
        });
      }
    }
  }

  Future<AcpSessionLaunchResult?> _resolveConcurrency(
    AcpConcurrencyRequiresChoice decision,
  ) async {
    final manager = ref.read(acpSessionManagerProvider);
    final choice = await showAcpConcurrencyChoice(
      context,
      decision: decision,
      managerState: manager.state,
    );
    if (choice == null || !mounted) {
      return null;
    }
    switch (choice) {
      case AcpConcurrencyChoice.stopAndContinue:
        final blocking = [
          for (final value in decision.blockingSessionKeys)
            manager.state.byKeyValue(value)?.key,
        ].whereType<AcpSessionKey>().toList(growable: false);
        return _launch(replace: blocking);
      case AcpConcurrencyChoice.upgrade:
        await context.push<void>(
          Uri(
            path: '/upgrade',
            queryParameters: {
              'feature': MonetizationFeature.concurrentAcpSessions.name,
            },
          ).toString(),
        );
        if (!mounted) {
          return null;
        }
        final unlocked = ref
            .read(monetizationServiceProvider)
            .currentState
            .isProUnlocked;
        if (!unlocked) {
          return null;
        }
        return _launch();
    }
  }

  Future<void> _handleFailure(AcpSessionError error) async {
    final providerId = _providerId;
    switch (error.kind) {
      case AcpSessionErrorKind.authenticationRequired:
        if (providerId != null) {
          await _showAuthRequired(providerId);
        }
      case AcpSessionErrorKind.commandNotApproved:
        setState(
          () => _error =
              'This provider needs its command reviewed again before it '
              'can launch. Edit it to re-approve.',
        );
      default:
        setState(() => _error = error.message);
    }
  }

  Future<void> _showAuthRequired(String providerId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign in required'),
        content: const Text(
          'This agent needs you to sign in first. Open a terminal to complete '
          'its sign-in flow, then start the session again. MonkeySSH never '
          'stores third-party credentials.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open Terminal'),
          ),
        ],
      ),
    );
    if ((confirmed ?? false) && mounted) {
      await _openTerminalForAuth(providerId);
    }
  }

  Future<void> _addCustomProvider() async {
    final result = await showAcpCustomProviderEditor(
      context,
      providerService: ref.read(acpProviderServiceProvider),
    );
    if (result?.saved != null && mounted) {
      setState(() => _providerId = result!.saved!.id);
    }
  }

  Future<void> _editCustomProvider(AcpCustomProviderView provider) async {
    await showAcpCustomProviderEditor(
      context,
      providerService: ref.read(acpProviderServiceProvider),
      existing: provider.definition,
    );
  }

  /// Opens the created session's chat, returning its key to the caller.
  void _openChat() {
    final key = _configuringKey;
    if (key == null) {
      return;
    }
    Navigator.of(context).pop(key);
  }

  Widget _buildConfigStage(AcpSessionKey key) {
    final colorScheme = Theme.of(context).colorScheme;
    // Load the created session's live state so advertised options, model, and
    // mode stay in sync as they stream in after launch.
    final manager = ref.read(acpSessionManagerProvider);
    final managerState =
        ref.watch(acpSessionManagerStateProvider).asData?.value ??
        manager.state;
    final session = managerState.byKeyValue(key.value);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return PopScope(
      canPop: !_busy,
      child: Padding(
        padding: EdgeInsets.only(
          left: FluttyTheme.spacingLg,
          right: FluttyTheme.spacingLg,
          bottom:
              MediaQuery.viewInsetsOf(context).bottom + FluttyTheme.spacingSm,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'configure session',
                style: FluttyTheme.displayMono(
                  fontSize: 18,
                  color: colorScheme.onSurface,
                ),
              ),
              if (session != null) ...[
                const SizedBox(height: FluttyTheme.spacingXs),
                Text(
                  '${session.providerLabel} · ${acpCwdSummary(session.cwd)}',
                  style: FluttyTheme.monoStyle.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: FluttyTheme.spacingSm),
              if (session == null)
                const Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: FluttyTheme.spacingLg,
                  ),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Flexible(
                  child: AcpConfigOptionControls(
                    options: session.configOptions,
                    onSetConfigOption: (configId, value) => manager
                        .setConfigOption(key, configId: configId, value: value),
                    modeState: session.modeState,
                    modelState: session.modelState,
                    onSetMode: (modeId) => manager.setMode(key, modeId),
                    onSetModel: (modelId) => manager.setModel(key, modelId),
                    enabled: session.status == AcpConnectionStatus.ready,
                  ),
                ),
              const SizedBox(height: FluttyTheme.spacingMd),
              FilledButton.icon(
                onPressed: _openChat,
                icon: const Icon(Icons.forum_outlined),
                label: Text(
                  _hasAdjustableSettings(session)
                      ? 'Open chat'
                      : 'Skip · Open chat',
                ),
              ),
              const SizedBox(height: FluttyTheme.spacingSm),
            ],
          ),
        ),
      ),
    );
  }

  bool _hasAdjustableSettings(AcpSessionState? session) {
    if (session == null) {
      return false;
    }
    if (session.configOptions.isNotEmpty) {
      return true;
    }
    final mode = session.modeState;
    if (mode != null && mode.availableModes.isNotEmpty) {
      return true;
    }
    final model = session.modelState;
    return model != null && model.availableModels.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    if (_configuringKey != null) {
      return _buildConfigStage(_configuringKey!);
    }
    final colorScheme = Theme.of(context).colorScheme;
    final hostsAsync = ref.watch(allHostsProvider);
    final providersAsync = ref.watch(acpProvidersProvider);
    final hosts = hostsAsync.asData?.value;
    final providers = providersAsync.asData?.value;
    if (hosts != null && providers != null) {
      _scheduleDefaults(hosts, providers);
    } else if (!_defaultsScheduled &&
        !hostsAsync.isLoading &&
        !providersAsync.isLoading) {
      _scheduleDefaults(
        hosts ?? const <Host>[],
        providers ?? const <AcpProvider>[],
      );
    }
    final controlsDisabled = _busy || _loadingDefaults;

    return PopScope(
      // Block dismissal (back gesture / predictive pop) while a launch is in
      // flight so an in-progress connect/start can't be interrupted or leave
      // the sheet updating state after it is gone.
      canPop: !_busy,
      child: Padding(
        padding: EdgeInsets.only(
          left: FluttyTheme.spacingLg,
          right: FluttyTheme.spacingLg,
          bottom:
              MediaQuery.viewInsetsOf(context).bottom + FluttyTheme.spacingLg,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'new agent session',
                style: FluttyTheme.displayMono(
                  fontSize: 18,
                  color: colorScheme.onSurface,
                ),
              ),
              if (_loadingDefaults) ...[
                const SizedBox(height: FluttyTheme.spacingSm),
                const LinearProgressIndicator(),
              ],
              const SizedBox(height: FluttyTheme.spacingMd),
              _sectionLabel(context, 'Host'),
              hostsAsync.when(
                data: (hosts) {
                  if (hosts.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: FluttyTheme.spacingSm,
                      ),
                      child: Text('Add a host first to launch an agent.'),
                    );
                  }
                  return DropdownButtonFormField<int>(
                    initialValue: _hostId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      hintText: 'Choose a host',
                    ),
                    items: [
                      for (final host in hosts)
                        DropdownMenuItem<int>(
                          value: host.id,
                          child: Text(
                            host.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: controlsDisabled
                        ? null
                        : (value) => unawaited(
                            _selectHost(
                              value,
                              hosts,
                              providers ?? const <AcpProvider>[],
                            ),
                          ),
                  );
                },
                loading: () => const Padding(
                  padding: EdgeInsets.all(FluttyTheme.spacingMd),
                  child: LinearProgressIndicator(),
                ),
                error: (_, _) => const Text('Could not load hosts.'),
              ),
              const SizedBox(height: FluttyTheme.spacingMd),
              _sectionLabel(context, 'Provider'),
              providersAsync.when(
                data: _buildProviderPicker,
                loading: () => const Padding(
                  padding: EdgeInsets.all(FluttyTheme.spacingMd),
                  child: LinearProgressIndicator(),
                ),
                error: (_, _) => const Text('Could not load providers.'),
              ),
              const SizedBox(height: FluttyTheme.spacingMd),
              _sectionLabel(context, 'Working directory'),
              TextField(
                controller: _cwd,
                enabled: !controlsDisabled,
                autocorrect: false,
                enableSuggestions: false,
                style: FluttyTheme.monoStyle,
                onChanged: (_) => _cwdEdited = true,
                decoration: const InputDecoration(hintText: '~'),
              ),
              _buildRecentSessions(),
              if (_error != null) ...[
                const SizedBox(height: FluttyTheme.spacingMd),
                Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: colorScheme.error,
                    ),
                    const SizedBox(width: FluttyTheme.spacingSm),
                    Expanded(
                      child: Text(
                        _error!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: FluttyTheme.spacingLg),
              FilledButton.icon(
                onPressed:
                    (controlsDisabled || _hostId == null || _providerId == null)
                    ? null
                    : _start,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(
                  _selectedRecent != null ? 'Resume session' : 'Start session',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProviderPicker(List<AcpProvider> providers) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: FluttyTheme.spacingSm,
        runSpacing: FluttyTheme.spacingSm,
        children: [
          for (final provider in providers)
            _ProviderChip(
              key: ValueKey('provider-${provider.id}'),
              provider: provider,
              selected: provider.id == _providerId,
              onSelected: (_busy || _loadingDefaults)
                  ? null
                  : () => setState(() {
                      _providerId = provider.id;
                      _selectedRecent = null;
                    }),
              onEdit:
                  (provider is AcpCustomProviderView &&
                      !_busy &&
                      !_loadingDefaults)
                  ? () => _editCustomProvider(provider)
                  : null,
            ),
        ],
      ),
      const SizedBox(height: FluttyTheme.spacingXs),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: (_busy || _loadingDefaults) ? null : _addCustomProvider,
          icon: const Icon(Icons.add),
          label: const Text('Add custom provider'),
        ),
      ),
    ],
  );

  Widget _buildRecentSessions() {
    final hostId = _hostId;
    final providerId = _providerId;
    if (hostId == null || providerId == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<List<AcpRecentSessionRef>>(
      future: _recents,
      builder: (context, snapshot) {
        final recents = (snapshot.data ?? const <AcpRecentSessionRef>[])
            .where((r) => r.hostId == hostId && r.providerId == providerId)
            .toList(growable: false);
        if (recents.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: FluttyTheme.spacingMd),
            _sectionLabel(context, 'Resume a recent session'),
            RadioGroup<AcpRecentSessionRef?>(
              groupValue: _selectedRecent,
              onChanged: (value) {
                if (_busy) {
                  return;
                }
                setState(() => _selectedRecent = value);
              },
              child: Column(
                children: [
                  const RadioListTile<AcpRecentSessionRef?>(
                    value: null,
                    title: Text('Start a new session'),
                    contentPadding: EdgeInsets.zero,
                  ),
                  for (final recent in recents)
                    RadioListTile<AcpRecentSessionRef?>(
                      value: recent,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        recent.title?.trim().isNotEmpty ?? false
                            ? recent.title!
                            : 'Resume ${acpCwdSummary(recent.cwd)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'last active ${acpRelativeTime(recent.lastActivityAt)}',
                        style: FluttyTheme.monoStyle,
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sectionLabel(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: FluttyTheme.spacingXs),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge),
  );
}

class _ProviderChip extends StatelessWidget {
  const _ProviderChip({
    required this.provider,
    required this.selected,
    required this.onSelected,
    this.onEdit,
    super.key,
  });

  final AcpProvider provider;
  final bool selected;
  final VoidCallback? onSelected;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) => InputChip(
    label: Text(provider.label),
    selected: selected,
    onSelected: onSelected == null ? null : (_) => onSelected!(),
    avatar: Icon(
      provider.isCustom ? Icons.terminal : Icons.smart_toy_outlined,
      size: 18,
    ),
    onDeleted: onEdit,
    deleteIcon: onEdit == null ? null : const Icon(Icons.edit, size: 16),
    deleteButtonTooltipMessage: onEdit == null ? null : 'Edit provider',
  );
}

// Re-exported so this sheet does not depend on the notification-navigation
// layer just for the home fallback location.
/// Builds the Connections-tab home location used as the base of the
/// Open Terminal stack.
String buildTmuxAlertHomeLocationSafe() =>
    Uri(path: '/', queryParameters: const {'tab': 'connections'}).toString();
