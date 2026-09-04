// Generated POSIX and PowerShell fragments intentionally mix raw and interpolated strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings, use_raw_strings

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_launch_preset.dart';
import '../models/agent_runtime_info.dart';
import 'agent_session_discovery_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'windows_remote_powershell.dart';

const _profilePrefix =
    r'export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; '
    '{ . ~/.profile; . ~/.bash_profile; . ~/.zprofile; } >/dev/null 2>&1; '
    r'case "${SHELL##*/}" in '
    'zsh) { . ~/.zshrc; } >/dev/null 2>&1;; '
    'bash) { . ~/.bashrc; } >/dev/null 2>&1;; '
    'esac; '
    r'export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; ';
const _pathMarker = '__monkeyssh_agent_path__=';
const _versionMarker = '__monkeyssh_agent_version__=';
const _runtimeMarker = '__monkeyssh_agent_runtime__=';
const _runtimeEndMarker = '__monkeyssh_agent_runtime_end__';
const _sourceMarker = '__monkeyssh_agent_source__=';
const _latestMarker = '__monkeyssh_agent_latest__=';
const _installedMarker = '__monkeyssh_agent_installed__=';

/// Supported remote coding-agent CLIs.
const agentCliRuntimeDefinitions = <AgentRuntimeDefinition>[
  AgentRuntimeDefinition(
    id: 'cli:claude',
    label: 'Claude Code',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.claudeCode,
    executableNames: ['claude', 'claude-code'],
    registry: AgentPackageRegistry.npm,
    packageName: '@anthropic-ai/claude-code',
    selfUpdateArguments: ['update'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:copilot',
    label: 'Copilot CLI',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.copilotCli,
    executableNames: ['copilot', 'github-copilot'],
    registry: AgentPackageRegistry.npm,
    packageName: '@github/copilot',
    selfUpdateArguments: ['update'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:codex',
    label: 'Codex',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.codex,
    executableNames: ['codex', 'codex-cli'],
    registry: AgentPackageRegistry.npm,
    packageName: '@openai/codex',
    selfUpdateArguments: ['update'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:gemini',
    label: 'Gemini CLI',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.geminiCli,
    executableNames: ['gemini', 'gemini-cli'],
    registry: AgentPackageRegistry.npm,
    packageName: '@google/gemini-cli',
    selfUpdateArguments: ['update'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:opencode',
    label: 'OpenCode',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.openCode,
    executableNames: ['opencode', 'open-code'],
    registry: AgentPackageRegistry.npm,
    packageName: 'opencode-ai',
    homebrewFormula: 'opencode',
    selfUpdateArguments: ['upgrade'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:antigravity',
    label: 'Antigravity',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.antigravity,
    executableNames: ['agy', 'antigravity', 'antigravity-cli'],
    selfUpdateArguments: ['update'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:cursor',
    label: 'Cursor Agent',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.cursorAgent,
    executableNames: ['cursor-agent'],
    selfUpdateArguments: ['update'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:pi',
    label: 'Pi',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.pi,
    executableNames: ['pi'],
    registry: AgentPackageRegistry.npm,
    packageName: '@mariozechner/pi-coding-agent',
    selfUpdateArguments: ['update', '--self'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:hermes',
    label: 'Hermes',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.hermes,
    executableNames: ['hermes', 'hermes-agent'],
    registry: AgentPackageRegistry.pipx,
    packageName: 'hermes-agent',
    selfUpdateArguments: ['update', '--yes'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:openclaw',
    label: 'OpenClaw',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.openclaw,
    executableNames: ['openclaw'],
    registry: AgentPackageRegistry.npm,
    packageName: 'openclaw',
    selfUpdateArguments: ['update', '--yes'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:grok',
    label: 'Grok Build',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.grokBuild,
    executableNames: ['grok'],
    selfUpdateArguments: ['update'],
  ),
];

/// Supported built-in ACP adapters.
const agentAcpRuntimeDefinitions = <AgentRuntimeDefinition>[
  AgentRuntimeDefinition(
    id: 'acp:copilot',
    label: 'Copilot CLI ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.copilotCli,
    executableNames: ['copilot', 'github-copilot'],
    registry: AgentPackageRegistry.npm,
    packageName: '@github/copilot',
    sharesCliInstallation: true,
  ),
  AgentRuntimeDefinition(
    id: 'acp:claude',
    label: 'Claude Agent ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.claudeCode,
    executableNames: ['claude-agent-acp'],
    registry: AgentPackageRegistry.npm,
    packageName: '@agentclientprotocol/claude-agent-acp',
  ),
  AgentRuntimeDefinition(
    id: 'acp:codex',
    label: 'Codex ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.codex,
    executableNames: ['codex-acp'],
    registry: AgentPackageRegistry.npm,
    packageName: '@agentclientprotocol/codex-acp',
  ),
  AgentRuntimeDefinition(
    id: 'acp:opencode',
    label: 'OpenCode ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.openCode,
    executableNames: ['opencode', 'open-code'],
    registry: AgentPackageRegistry.npm,
    packageName: 'opencode-ai',
    homebrewFormula: 'opencode',
    sharesCliInstallation: true,
  ),
  AgentRuntimeDefinition(
    id: 'acp:cursor',
    label: 'Cursor Agent ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.cursorAgent,
    executableNames: ['cursor-agent'],
    sharesCliInstallation: true,
  ),
  AgentRuntimeDefinition(
    id: 'acp:antigravity',
    label: 'Antigravity ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.antigravity,
    executableNames: ['agy-acp', 'antigravity-acp'],
    registry: AgentPackageRegistry.npm,
    packageName: 'agy-acp',
  ),
  AgentRuntimeDefinition(
    id: 'acp:pi',
    label: 'Pi ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.pi,
    executableNames: ['pi-acp'],
    registry: AgentPackageRegistry.npm,
    packageName: 'pi-acp',
  ),
  AgentRuntimeDefinition(
    id: 'acp:hermes',
    label: 'Hermes ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.hermes,
    executableNames: ['hermes', 'hermes-agent'],
    registry: AgentPackageRegistry.pipx,
    packageName: 'hermes-agent',
    sharesCliInstallation: true,
  ),
  AgentRuntimeDefinition(
    id: 'acp:openclaw',
    label: 'OpenClaw ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.openclaw,
    executableNames: ['openclaw'],
    registry: AgentPackageRegistry.npm,
    packageName: 'openclaw',
    sharesCliInstallation: true,
  ),
  AgentRuntimeDefinition(
    id: 'acp:grok',
    label: 'Grok Build ACP',
    kind: AgentRuntimeKind.acpAdapter,
    tool: AgentLaunchTool.grokBuild,
    executableNames: ['grok'],
    sharesCliInstallation: true,
  ),
];

/// All managed runtimes in display order.
const agentRuntimeDefinitions = <AgentRuntimeDefinition>[
  ...agentCliRuntimeDefinitions,
  ...agentAcpRuntimeDefinitions,
];

/// Extracts a normalized version from common CLI output.
String? parseAgentVersion(String output) {
  final match = RegExp(
    r'(?<![A-Za-z0-9])v?(\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?)',
  ).firstMatch(output);
  return match?.group(1);
}

/// Compares two semantic-style versions.
///
/// Returns a negative value when [left] is older than [right].
int compareAgentVersions(String left, String right) {
  ({List<int> numbers, String? pre}) split(String value) {
    final coreAndPre = value.replaceFirst(RegExp('^[vV]'), '').split('+').first;
    final dash = coreAndPre.indexOf('-');
    final core = dash < 0 ? coreAndPre : coreAndPre.substring(0, dash);
    return (
      numbers: core.split('.').map((part) => int.tryParse(part) ?? 0).toList(),
      pre: dash < 0 ? null : coreAndPre.substring(dash + 1),
    );
  }

  final a = split(left);
  final b = split(right);
  final count = a.numbers.length > b.numbers.length
      ? a.numbers.length
      : b.numbers.length;
  for (var index = 0; index < count; index++) {
    final av = index < a.numbers.length ? a.numbers[index] : 0;
    final bv = index < b.numbers.length ? b.numbers[index] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  if (a.pre == b.pre) return 0;
  if (a.pre == null) return 1;
  if (b.pre == null) return -1;
  return a.pre!.compareTo(b.pre!);
}

/// Builds the remote install or update command for [definition].
String? buildAgentInstallCommand(
  AgentRuntimeDefinition definition, {
  required bool windows,
  required bool update,
  String? detectionSource,
  String? executablePath,
}) {
  if (update && executablePath != null && definition.supportsSelfUpdate) {
    if (windows) {
      final executable = powerShellSingleQuote(executablePath);
      final arguments = definition.selfUpdateArguments
          .map(powerShellSingleQuote)
          .join(' ');
      return buildWindowsPowerShellCommand(
        '$powerShellProfilePathPreamble& $executable $arguments; exit \u0024LASTEXITCODE',
      );
    }
    return '$_profilePrefix${_shellQuote(executablePath)} '
        '${definition.selfUpdateArguments.map(_shellQuote).join(' ')}';
  }
  if (update && detectionSource == 'PATH') return null;
  final formula = definition.homebrewFormula;
  if (update && detectionSource == 'Homebrew' && formula != null) {
    return windows
        ? null
        : '$_profilePrefix brew upgrade ${_shellQuote(formula)}';
  }
  final package = definition.packageName;
  if (package == null) return null;
  if (windows) {
    final quotedPackage = powerShellSingleQuote(package);
    final quotedLatest = powerShellSingleQuote('$package@latest');
    final script = switch (definition.registry) {
      AgentPackageRegistry.npm => [
        powerShellProfilePathPreamble,
        '& npm install -g $quotedLatest;',
        r'exit $LASTEXITCODE',
      ].join(),
      AgentPackageRegistry.pipx => [
        powerShellProfilePathPreamble,
        'if(Get-Command pipx -ErrorAction SilentlyContinue){',
        if (update)
          '& pipx upgrade $quotedPackage;'
        else
          '& pipx install $quotedPackage;',
        r'if($LASTEXITCODE -eq 0){exit 0}};',
        if (update)
          '& py -m pip install --user --upgrade $quotedPackage;'
        else
          '& py -m pip install --user $quotedPackage;',
        r'exit $LASTEXITCODE',
      ].join(),
      null => null,
    };
    return script == null ? null : buildWindowsPowerShellCommand(script);
  }
  return switch (definition.registry) {
    AgentPackageRegistry.npm =>
      '$_profilePrefix npm install -g ${_shellQuote(package)}@latest',
    AgentPackageRegistry.pipx =>
      update
          ? '$_profilePrefix pipx upgrade ${_shellQuote(package)} || python3 -m pip install --user --upgrade ${_shellQuote(package)}'
          : '$_profilePrefix pipx install ${_shellQuote(package)} || python3 -m pip install --user ${_shellQuote(package)}',
    null => null,
  };
}

/// Inspects and manages coding-agent runtimes over non-interactive SSH exec.
class AgentManagementService {
  /// Creates the service.
  AgentManagementService(this._discovery);

  static const _updateCheckTtl = Duration(minutes: 15);

  final AgentSessionDiscoveryService _discovery;
  final Map<int, ({DateTime checkedAt, List<AgentRuntimeInfo> runtimes})>
  _runtimeCache = {};
  final Map<int, Future<List<AgentRuntimeInfo>>> _inFlightUpdateChecks = {};

  /// Returns cached update information or probes the active host.
  Future<List<AgentRuntimeInfo>> checkForUpdates(SshSession session) {
    final cached = _runtimeCache[session.connectionId];
    if (cached != null &&
        DateTime.now().difference(cached.checkedAt) < _updateCheckTtl) {
      return Future.value(cached.runtimes);
    }
    final existing = _inFlightUpdateChecks[session.connectionId];
    if (existing != null) return existing;

    late final Future<List<AgentRuntimeInfo>> check;
    check =
        _inspectAll(
          session,
          priority: SshExecPriority.low,
          includeAdapters: false,
        ).whenComplete(() {
          if (identical(_inFlightUpdateChecks[session.connectionId], check)) {
            _inFlightUpdateChecks.remove(session.connectionId);
          }
        });
    _inFlightUpdateChecks[session.connectionId] = check;
    return check;
  }

  /// Invalidates session discovery and probes every supported runtime.
  Future<List<AgentRuntimeInfo>> refreshAll(SshSession session) async {
    final inFlight = _inFlightUpdateChecks[session.connectionId];
    if (inFlight != null) {
      try {
        await inFlight;
      } on Object {
        // A stale background failure must not abort an explicit refresh.
      }
    }
    _discovery.invalidateSession(session);
    return _inspectAll(session);
  }

  Future<List<AgentRuntimeInfo>> _inspectAll(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.normal,
    bool includeAdapters = true,
  }) async {
    final definitions = <AgentRuntimeDefinition>[
      ...agentCliRuntimeDefinitions,
      if (includeAdapters)
        ...agentAcpRuntimeDefinitions.where(
          (definition) => !definition.sharesCliInstallation,
        ),
    ];
    final AgentRuntimeActionResult batch;
    try {
      batch = await _run(
        session,
        buildAgentBatchProbeCommand(
          definitions,
          windows: session.remoteIsWindows,
        ),
        priority: priority,
        timeout: const Duration(seconds: 5),
      );
    } on Object catch (error) {
      final failed = [
        for (final definition in definitions)
          AgentRuntimeInfo(
            definition: definition,
            status: AgentRuntimeStatus.failed,
            message: error.toString(),
          ),
      ];
      return _assembleRuntimeList(
        session,
        failed,
        includeAdapters: includeAdapters,
      );
    }
    final snapshots = parseAgentBatchProbeOutput(batch.output);
    final installedDefinitions = definitions
        .where((definition) => snapshots[definition.id]?.executablePath != null)
        .toList(growable: false);
    var metadata = <String, AgentMetadataSnapshot>{};
    if (installedDefinitions.isNotEmpty) {
      try {
        final metadataOutput = await _run(
          session,
          buildAgentMetadataProbeCommand(
            installedDefinitions,
            windows: session.remoteIsWindows,
          ),
          priority: priority,
          timeout: const Duration(seconds: 10),
        );
        metadata = parseAgentMetadataProbeOutput(metadataOutput.output);
      } on Object {
        // Registry metadata is best-effort; installed tools remain visible.
      }
    }
    final uniqueRuntimes = await Future.wait(
      definitions.map(
        (definition) => _resolveRuntimeInfo(
          session,
          definition,
          snapshots[definition.id] ?? const AgentProbeSnapshot(),
          priority: priority,
          metadata: metadata[definition.id],
          metadataWasBatched: true,
        ),
      ),
    );
    return _assembleRuntimeList(
      session,
      uniqueRuntimes,
      includeAdapters: includeAdapters,
    );
  }

  List<AgentRuntimeInfo> _assembleRuntimeList(
    SshSession session,
    List<AgentRuntimeInfo> uniqueRuntimes, {
    required bool includeAdapters,
  }) {
    final byId = {
      for (final runtime in uniqueRuntimes) runtime.definition.id: runtime,
    };
    final cliByTool = <AgentLaunchTool, AgentRuntimeInfo>{};
    final runtimes = <AgentRuntimeInfo>[];
    for (final definition in agentCliRuntimeDefinitions) {
      final runtime = byId[definition.id];
      if (runtime == null) continue;
      runtimes.add(runtime);
      final tool = definition.tool;
      if (tool != null) cliByTool[tool] = runtime;
    }
    if (includeAdapters) {
      for (final definition in agentAcpRuntimeDefinitions) {
        final shared = definition.sharesCliInstallation
            ? cliByTool[definition.tool]
            : null;
        final runtime = shared == null
            ? byId[definition.id]
            : _copyAcpRuntimeInfo(shared, definition);
        if (runtime != null) runtimes.add(runtime);
      }
    }
    _runtimeCache[session.connectionId] = (
      checkedAt: DateTime.now(),
      runtimes: runtimes,
    );
    return runtimes;
  }

  /// Probes one runtime and checks its package registry for a newer version.
  Future<AgentRuntimeInfo> inspect(
    SshSession session,
    AgentRuntimeDefinition definition, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    try {
      final probeOutput = await _run(
        session,
        buildAgentProbeCommand(definition, windows: session.remoteIsWindows),
        priority: priority,
        timeout: const Duration(seconds: 5),
      );
      final snapshot = AgentProbeSnapshot(
        executablePath: _markerValue(probeOutput.output, _pathMarker),
      );
      AgentMetadataSnapshot? metadata;
      if (snapshot.executablePath != null) {
        final metadataOutput = await _run(
          session,
          buildAgentMetadataProbeCommand([
            definition,
          ], windows: session.remoteIsWindows),
          priority: priority,
          timeout: const Duration(seconds: 10),
        );
        metadata = parseAgentMetadataProbeOutput(
          metadataOutput.output,
        )[definition.id];
      }
      return _resolveRuntimeInfo(
        session,
        definition,
        snapshot,
        priority: priority,
        metadata: metadata,
        metadataWasBatched: true,
      );
    } on Object catch (error) {
      return AgentRuntimeInfo(
        definition: definition,
        status: AgentRuntimeStatus.failed,
        message: error.toString(),
      );
    }
  }

  Future<AgentRuntimeInfo> _resolveRuntimeInfo(
    SshSession session,
    AgentRuntimeDefinition definition,
    AgentProbeSnapshot snapshot, {
    required SshExecPriority priority,
    AgentMetadataSnapshot? metadata,
    bool metadataWasBatched = false,
  }) async {
    final path = snapshot.executablePath;
    var installed = parseAgentVersion(snapshot.versionOutput ?? '');
    if (path == null) {
      return AgentRuntimeInfo(
        definition: definition,
        status: AgentRuntimeStatus.notInstalled,
        message: definition.supportsManagedInstall
            ? null
            : 'Install this tool using its official installer.',
      );
    }
    var source = metadata?.detectionSource ?? _detectionSourceFromPath(path);
    installed ??= parseAgentVersion(metadata?.installedVersionOutput ?? '');
    var latest = definition.kind == AgentRuntimeKind.cli
        ? parseAgentVersion(metadata?.latestVersionOutput ?? '')
        : null;
    if (!metadataWasBatched) {
      try {
        source = await _detectInstallationSource(
          session,
          definition,
          path,
          priority: priority,
        );
      } on Object {
        // Ownership lookup is best-effort; the executable itself was found.
      }
      try {
        latest = await _readLatestVersion(
          session,
          definition,
          priority: priority,
        );
      } on Object {
        // An offline registry must not hide an installed runtime.
      }
    }
    final hasUpdate =
        installed != null &&
        latest != null &&
        compareAgentVersions(installed, latest) < 0;
    final managed =
        definition.supportsSelfUpdate ||
        source == 'Homebrew' ||
        source == 'npm global' ||
        source == 'pipx';
    return AgentRuntimeInfo(
      definition: definition,
      status: hasUpdate
          ? AgentRuntimeStatus.updateAvailable
          : AgentRuntimeStatus.installed,
      installedVersion: installed,
      latestVersion: latest,
      executablePath: path,
      detectionSource: source,
      managedByPackageManager: managed,
      message: hasUpdate && !managed
          ? 'Update this PATH installation with its original installer, then re-check.'
          : null,
    );
  }

  /// Installs or updates [definition], forwarding command output as it arrives.
  Future<AgentRuntimeActionResult> installOrUpdate(
    SshSession session,
    AgentRuntimeDefinition definition, {
    required bool update,
    AgentRuntimeInfo? current,
    ValueChanged<String>? onOutput,
  }) async {
    final command = buildAgentInstallCommand(
      definition,
      windows: session.remoteIsWindows,
      update: update,
      detectionSource: current?.detectionSource,
      executablePath: current?.executablePath,
    );
    if (command == null) {
      return const AgentRuntimeActionResult(
        succeeded: false,
        output:
            'No safe automatic installer is available for this tool. Use its official installation instructions, then tap Re-check.',
      );
    }
    final result = await _run(
      session,
      command,
      onOutput: onOutput,
      timeout: null,
    );
    _runtimeCache.remove(session.connectionId);
    _discovery.invalidateSession(session);
    return result;
  }

  Future<String> _detectInstallationSource(
    SshSession session,
    AgentRuntimeDefinition definition,
    String path, {
    required SshExecPriority priority,
  }) async {
    final formula = definition.homebrewFormula;
    if (!session.remoteIsWindows && formula != null) {
      final result = await _run(
        session,
        '$_profilePrefix command -v brew >/dev/null 2>&1 && brew list --versions ${_shellQuote(formula)} 2>/dev/null',
        priority: priority,
      );
      if (result.output.contains(formula) &&
          parseAgentVersion(result.output) != null) {
        return 'Homebrew';
      }
    }

    final package = definition.packageName;
    if (package != null && definition.registry != null) {
      final command = switch (definition.registry!) {
        AgentPackageRegistry.npm when session.remoteIsWindows =>
          _windowsNpmCommand(['list', '-g', '--depth=0', package]),
        AgentPackageRegistry.npm =>
          '$_profilePrefix npm list -g --depth=0 ${_shellQuote(package)} 2>/dev/null',
        AgentPackageRegistry.pipx when session.remoteIsWindows =>
          _windowsExecutableCommand('pipx', ['list', '--short']),
        AgentPackageRegistry.pipx =>
          '$_profilePrefix pipx list --short 2>/dev/null',
      };
      final result = await _run(session, command, priority: priority);
      if (result.succeeded &&
          result.output.toLowerCase().contains(package.toLowerCase())) {
        return definition.registry == AgentPackageRegistry.npm
            ? 'npm global'
            : 'pipx';
      }
    }
    return _detectionSourceFromPath(path);
  }

  Future<String?> _readLatestVersion(
    SshSession session,
    AgentRuntimeDefinition definition, {
    required SshExecPriority priority,
  }) async {
    final package = definition.packageName;
    if (package == null || definition.registry == null) return null;
    final command = switch (definition.registry!) {
      AgentPackageRegistry.npm when session.remoteIsWindows =>
        _windowsNpmCommand(['view', package, 'version']),
      AgentPackageRegistry.npm =>
        '$_profilePrefix npm view ${_shellQuote(package)} version 2>/dev/null',
      AgentPackageRegistry.pipx when session.remoteIsWindows =>
        _windowsPipCommand(['-m', 'pip', 'index', 'versions', package]),
      AgentPackageRegistry.pipx =>
        '$_profilePrefix python3 -m pip index versions ${_shellQuote(package)} 2>/dev/null | head -n 1',
    };
    final result = await _run(session, command, priority: priority);
    return parseAgentVersion(result.output);
  }

  Future<AgentRuntimeActionResult> _run(
    SshSession session,
    String command, {
    ValueChanged<String>? onOutput,
    Duration? timeout = const Duration(seconds: 15),
    SshExecPriority priority = SshExecPriority.normal,
  }) => session.runQueuedExec(() async {
    final exec = await session.execute(command);
    try {
      final output = StringBuffer();
      void add(String chunk) {
        output.write(chunk);
        onOutput?.call(chunk);
      }

      final stdout = exec.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach(add);
      final stderr = exec.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach(add);
      final completion = Future.wait<void>([stdout, stderr, exec.done]);
      if (timeout == null) {
        await completion;
      } else {
        await completion.timeout(timeout);
      }
      final exitCode = exec.exitCode;
      return AgentRuntimeActionResult(
        succeeded: exitCode == null || exitCode == 0,
        output: output.toString().trim(),
        exitCode: exitCode,
      );
    } finally {
      exec.close();
    }
  }, priority: priority);
}

AgentRuntimeInfo _copyAcpRuntimeInfo(
  AgentRuntimeInfo source,
  AgentRuntimeDefinition definition,
) => AgentRuntimeInfo(
  definition: definition,
  status: switch (source.status) {
    AgentRuntimeStatus.checking => AgentRuntimeStatus.checking,
    AgentRuntimeStatus.notInstalled => AgentRuntimeStatus.notInstalled,
    AgentRuntimeStatus.failed => AgentRuntimeStatus.failed,
    AgentRuntimeStatus.unavailable => AgentRuntimeStatus.unavailable,
    AgentRuntimeStatus.installed ||
    AgentRuntimeStatus.updateAvailable => AgentRuntimeStatus.installed,
  },
  installedVersion: source.installedVersion,
  executablePath: source.executablePath,
  detectionSource: source.detectionSource,
  managedByPackageManager: source.managedByPackageManager,
);

String _windowsNpmCommand(List<String> arguments) =>
    _windowsExecutableCommand('npm', arguments);

String _windowsPipCommand(List<String> arguments) =>
    _windowsExecutableCommand('py', arguments);

String _windowsExecutableCommand(String executable, List<String> arguments) {
  final argv = arguments.map(powerShellSingleQuote).join(' ');
  return buildWindowsPowerShellCommand(
    '$powerShellProfilePathPreamble& $executable $argv; exit \$LASTEXITCODE',
  );
}

/// Parsed executable and version output for one runtime probe.
class AgentProbeSnapshot {
  /// Creates a probe snapshot.
  const AgentProbeSnapshot({this.executablePath, this.versionOutput});

  /// Resolved remote executable path.
  final String? executablePath;

  /// Raw normalized output from the runtime's version command.
  final String? versionOutput;
}

/// Package ownership and latest-version output for one runtime.
class AgentMetadataSnapshot {
  /// Creates a metadata snapshot.
  const AgentMetadataSnapshot({
    this.detectionSource,
    this.installedVersionOutput,
    this.latestVersionOutput,
  });

  /// Package manager that owns the installed executable.
  final String? detectionSource;

  /// Installed package version reported by the owning package manager.
  final String? installedVersionOutput;

  /// Raw output from the upstream version lookup.
  final String? latestVersionOutput;
}

/// Parses marker-delimited package ownership and latest-version output.
Map<String, AgentMetadataSnapshot> parseAgentMetadataProbeOutput(
  String output,
) {
  final snapshots = <String, AgentMetadataSnapshot>{};
  String? id;
  String? source;
  String? installed;
  String? latest;
  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trim();
    if (line.startsWith(_runtimeMarker)) {
      id = line.substring(_runtimeMarker.length);
      source = null;
      installed = null;
      latest = null;
    } else if (id != null && line.startsWith(_sourceMarker)) {
      source = line.substring(_sourceMarker.length).trim();
    } else if (id != null && line.startsWith(_installedMarker)) {
      installed = line.substring(_installedMarker.length).trim();
    } else if (id != null && line.startsWith(_latestMarker)) {
      latest = line.substring(_latestMarker.length).trim();
    } else if (id != null && line == _runtimeEndMarker) {
      snapshots[id] = AgentMetadataSnapshot(
        detectionSource: source == null || source.isEmpty ? null : source,
        installedVersionOutput: installed == null || installed.isEmpty
            ? null
            : installed,
        latestVersionOutput: latest == null || latest.isEmpty ? null : latest,
      );
      id = null;
    }
  }
  return snapshots;
}

/// Parses the marker-delimited output from [buildAgentBatchProbeCommand].
Map<String, AgentProbeSnapshot> parseAgentBatchProbeOutput(String output) {
  final snapshots = <String, AgentProbeSnapshot>{};
  String? id;
  String? path;
  String? version;
  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trim();
    if (line.startsWith(_runtimeMarker)) {
      id = line.substring(_runtimeMarker.length);
      path = null;
      version = null;
    } else if (id != null && line.startsWith(_pathMarker)) {
      path = line.substring(_pathMarker.length).trim();
    } else if (id != null && line.startsWith(_versionMarker)) {
      version = line.substring(_versionMarker.length).trim();
    } else if (id != null && line == _runtimeEndMarker) {
      snapshots[id] = AgentProbeSnapshot(
        executablePath: path == null || path.isEmpty ? null : path,
        versionOutput: version == null || version.isEmpty ? null : version,
      );
      id = null;
    }
  }
  return snapshots;
}

/// Builds one remote command that probes every [definition].
String buildAgentBatchProbeCommand(
  List<AgentRuntimeDefinition> definitions, {
  required bool windows,
}) {
  if (windows) {
    final body = StringBuffer(powerShellProfilePathPreamble);
    for (final definition in definitions) {
      body
        ..write(
          r'[void]$__flOut.AppendLine('
          '${powerShellSingleQuote('$_runtimeMarker${definition.id}')});',
        )
        ..write(_buildWindowsProbeBody(definition))
        ..write(
          r'[void]$__flOut.AppendLine('
          '${powerShellSingleQuote(_runtimeEndMarker)});',
        );
    }
    return buildWindowsPowerShellCommand(
      powerShellUtf8OutputScript(body.toString()),
    );
  }

  final command = StringBuffer(_profilePrefix);
  for (final definition in definitions) {
    command
      ..write('printf ${_shellQuote('$_runtimeMarker%s\\n')} ')
      ..write('${_shellQuote(definition.id)}; ')
      ..write(_buildPosixProbeBody(definition))
      ..write('; printf ${_shellQuote('$_runtimeEndMarker\\n')}; ');
  }
  return command.toString();
}

/// Builds one remote command for package ownership and upstream versions.
String buildAgentMetadataProbeCommand(
  List<AgentRuntimeDefinition> definitions, {
  required bool windows,
}) {
  if (windows) {
    final body = StringBuffer(powerShellProfilePathPreamble)
      ..write(
        r'$__flNpmGlobal=((& npm list -g --depth=0 2>$null | ForEach-Object {$_.ToString()}) -join "`n");',
      )
      ..write(
        r'$__flPipxGlobal=((& pipx list --short 2>$null | ForEach-Object {$_.ToString()}) -join "`n");',
      );
    for (final definition in definitions) {
      final package = definition.packageName;
      body
        ..write(
          r'[void]$__flOut.AppendLine('
          '${powerShellSingleQuote('$_runtimeMarker${definition.id}')});',
        )
        ..write(r'$__flLatest=$null;$__flInstalled=$null;');
      if (package != null && definition.registry == AgentPackageRegistry.npm) {
        final needle = powerShellSingleQuote('$package@');
        body.write(
          '\$__flNeedle=$needle;'
          r'$__flLine=($__flNpmGlobal -split "`n" | Where-Object { $_.Contains($__flNeedle) } | Select-Object -First 1);'
          r'if($null -ne $__flLine){'
          '[void]\$__flOut.AppendLine(${powerShellSingleQuote('$_sourceMarker npm global')});'
          r'$__flInstalled=$__flLine.Substring($__flLine.IndexOf($__flNeedle)+$__flNeedle.Length).Split(" ")[0]};',
        );
        if (definition.kind == AgentRuntimeKind.cli) {
          body.write(
            '\$__flLatest=(& npm view ${powerShellSingleQuote(package)} version --fetch-retries=0 --fetch-timeout=2500 2>\$null | Select-Object -First 1);',
          );
        }
      } else if (package != null &&
          definition.registry == AgentPackageRegistry.pipx) {
        final needle = powerShellSingleQuote(package);
        body.write(
          '\$__flNeedle=$needle;'
          r'$__flLine=($__flPipxGlobal -split "`n" | Where-Object { $_.Contains($__flNeedle) } | Select-Object -First 1);'
          r'if($null -ne $__flLine){'
          '[void]\$__flOut.AppendLine(${powerShellSingleQuote('$_sourceMarker pipx')});'
          r'$__flInstalled=($__flLine.Trim() -split "\s+")[1]};',
        );
        if (definition.kind == AgentRuntimeKind.cli) {
          body.write(
            '\$__flLatest=(& py -m pip index versions ${powerShellSingleQuote(package)} 2>\$null | Select-Object -First 1);',
          );
        }
      }
      body
        ..write(
          'if(\$null -ne \$__flInstalled){[void]\$__flOut.AppendLine('
          '${powerShellSingleQuote(_installedMarker)} + \$__flInstalled)};',
        )
        ..write(
          'if(\$null -ne \$__flLatest){[void]\$__flOut.AppendLine('
          '${powerShellSingleQuote(_latestMarker)} + \$__flLatest)};',
        )
        ..write(
          r'[void]$__flOut.AppendLine('
          '${powerShellSingleQuote(_runtimeEndMarker)});',
        );
    }
    return buildWindowsPowerShellCommand(
      powerShellUtf8OutputScript(body.toString()),
    );
  }

  final command = StringBuffer(_profilePrefix)
    ..write(r'__fl_npm_global=$(npm list -g --depth=0 2>/dev/null || true); ')
    ..write(r'__fl_pipx_global=$(pipx list --short 2>/dev/null || true); ')
    ..write(r'__fl_brew_global=$(brew list --versions 2>/dev/null || true); ');
  for (final definition in definitions) {
    final package = definition.packageName;
    final formula = definition.homebrewFormula;
    command
      ..write('printf ${_shellQuote('$_runtimeMarker%s\\n')} ')
      ..write('${_shellQuote(definition.id)}; ')
      ..write('__fl_source=; __fl_installed=; __fl_latest=; __fl_line=; ');
    if (formula != null) {
      command.write(
        '__fl_line=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_brew_global" | '
        'grep -E ${_shellQuote('^$formula([[:space:]]|\$)')} | head -n 1); '
        'if [ -n "\$__fl_line" ]; then '
        '__fl_source=${_shellQuote('Homebrew')}; '
        '__fl_installed=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_line" | awk ${_shellQuote('{print \u00242}')}); '
        'fi; ',
      );
    }
    if (package != null && definition.registry == AgentPackageRegistry.npm) {
      command.write(
        'if [ -z "\$__fl_source" ]; then '
        '__fl_line=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_npm_global" | '
        'grep -F -- ${_shellQuote('$package@')} | head -n 1); '
        'if [ -n "\$__fl_line" ]; then '
        '__fl_source=${_shellQuote('npm global')}; '
        '__fl_prefix=${_shellQuote('$package@')}; '
        '__fl_installed=\u0024{__fl_line##*"\$__fl_prefix"}; '
        '__fl_installed=\u0024{__fl_installed%% *}; '
        'fi; fi; ',
      );
      if (definition.kind == AgentRuntimeKind.cli) {
        command.write(
          '__fl_latest=\$(npm view ${_shellQuote(package)} version '
          '--fetch-retries=0 --fetch-timeout=2500 2>/dev/null | head -n 1); ',
        );
      }
    } else if (package != null &&
        definition.registry == AgentPackageRegistry.pipx) {
      command.write(
        'if [ -z "\$__fl_source" ]; then '
        '__fl_line=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_pipx_global" | '
        'grep -F -- ${_shellQuote(package)} | head -n 1); '
        'if [ -n "\$__fl_line" ]; then '
        '__fl_source=${_shellQuote('pipx')}; '
        '__fl_installed=\$(printf ${_shellQuote(r'%s\n')} "\$__fl_line" | awk ${_shellQuote('{print \u00242}')}); '
        'fi; fi; ',
      );
      if (definition.kind == AgentRuntimeKind.cli) {
        command.write(
          '__fl_latest=\$(python3 -m pip index versions ${_shellQuote(package)} 2>/dev/null | head -n 1); ',
        );
      }
    }
    command
      ..write(
        '[ -n "\$__fl_source" ] && printf ${_shellQuote('$_sourceMarker%s\\n')} "\$__fl_source"; ',
      )
      ..write(
        '[ -n "\$__fl_installed" ] && printf ${_shellQuote('$_installedMarker%s\\n')} "\$__fl_installed"; ',
      )
      ..write(
        '[ -n "\$__fl_latest" ] && printf ${_shellQuote('$_latestMarker%s\\n')} "\$__fl_latest"; ',
      )
      ..write('printf ${_shellQuote('$_runtimeEndMarker\\n')}; ');
  }
  return command.toString();
}

/// Builds a non-disruptive executable and version probe for the remote OS.
String buildAgentProbeCommand(
  AgentRuntimeDefinition definition, {
  required bool windows,
}) {
  if (windows) {
    return buildWindowsPowerShellCommand(
      powerShellUtf8OutputScript(
        '$powerShellProfilePathPreamble${_buildWindowsProbeBody(definition)}',
      ),
    );
  }
  return '$_profilePrefix${_buildPosixProbeBody(definition)}';
}

String _buildWindowsProbeBody(AgentRuntimeDefinition definition) {
  final quotedNames = definition.executableNames
      .map(powerShellSingleQuote)
      .join(',');
  return [
    '\$__flNames=@($quotedNames);',
    r'foreach($__flName in $__flNames){',
    r'$__flCommand=Get-Command $__flName -ErrorAction SilentlyContinue | Select-Object -First 1;',
    r'if($null -eq $__flCommand){continue};',
    '[void]\$__flOut.AppendLine(${powerShellSingleQuote(_pathMarker)} + \$__flCommand.Source);',
    'break}',
  ].join();
}

String _buildPosixProbeBody(AgentRuntimeDefinition definition) {
  final candidates = definition.executableNames.map(_shellQuote).join(' ');
  return 'for candidate in $candidates; do '
      r'resolved=$(command -v "$candidate" 2>/dev/null || true); '
      r'[ -z "$resolved" ] && continue; '
      'printf ${_shellQuote('$_pathMarker%s\\n')} "\$resolved"; '
      'break; done';
}

String? _markerValue(String output, String marker) {
  final index = output.indexOf(marker);
  if (index < 0) return null;
  final start = index + marker.length;
  final end = output.indexOf('\n', start);
  final value = output.substring(start, end < 0 ? output.length : end).trim();
  return value.isEmpty ? null : value;
}

String _detectionSourceFromPath(String path) {
  final normalized = path.toLowerCase();
  if (normalized.contains('/.cargo/')) return 'Cargo';
  return 'PATH';
}

String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Provider for [AgentManagementService].
final agentManagementServiceProvider = Provider<AgentManagementService>(
  (ref) =>
      AgentManagementService(ref.watch(agentSessionDiscoveryServiceProvider)),
);
