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
  ),
  AgentRuntimeDefinition(
    id: 'cli:copilot',
    label: 'Copilot CLI',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.copilotCli,
    executableNames: ['copilot', 'github-copilot'],
    registry: AgentPackageRegistry.npm,
    packageName: '@github/copilot',
  ),
  AgentRuntimeDefinition(
    id: 'cli:codex',
    label: 'Codex',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.codex,
    executableNames: ['codex', 'codex-cli'],
    registry: AgentPackageRegistry.npm,
    packageName: '@openai/codex',
  ),
  AgentRuntimeDefinition(
    id: 'cli:gemini',
    label: 'Gemini CLI',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.geminiCli,
    executableNames: ['gemini', 'gemini-cli'],
    registry: AgentPackageRegistry.npm,
    packageName: '@google/gemini-cli',
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
  ),
  AgentRuntimeDefinition(
    id: 'cli:antigravity',
    label: 'Antigravity',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.antigravity,
    executableNames: ['agy', 'antigravity', 'antigravity-cli'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:cursor',
    label: 'Cursor Agent',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.cursorAgent,
    executableNames: ['cursor-agent'],
  ),
  AgentRuntimeDefinition(
    id: 'cli:pi',
    label: 'Pi',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.pi,
    executableNames: ['pi'],
    registry: AgentPackageRegistry.npm,
    packageName: '@mariozechner/pi-coding-agent',
  ),
  AgentRuntimeDefinition(
    id: 'cli:hermes',
    label: 'Hermes',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.hermes,
    executableNames: ['hermes', 'hermes-agent'],
    registry: AgentPackageRegistry.pipx,
    packageName: 'hermes-agent',
  ),
  AgentRuntimeDefinition(
    id: 'cli:openclaw',
    label: 'OpenClaw',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.openclaw,
    executableNames: ['openclaw'],
    registry: AgentPackageRegistry.npm,
    packageName: 'openclaw',
  ),
  AgentRuntimeDefinition(
    id: 'cli:grok',
    label: 'Grok Build',
    kind: AgentRuntimeKind.cli,
    tool: AgentLaunchTool.grokBuild,
    executableNames: ['grok'],
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
}) {
  if (update && detectionSource == 'PATH') return null;
  final formula = definition.homebrewFormula;
  if (update && detectionSource == 'Homebrew' && formula != null) {
    return windows ? null : 'brew upgrade ${_shellQuote(formula)}';
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
    AgentPackageRegistry.npm => 'npm install -g ${_shellQuote(package)}@latest',
    AgentPackageRegistry.pipx =>
      update
          ? 'pipx upgrade ${_shellQuote(package)} || python3 -m pip install --user --upgrade ${_shellQuote(package)}'
          : 'pipx install ${_shellQuote(package)} || python3 -m pip install --user ${_shellQuote(package)}',
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
    check = _inspectAll(session, priority: SshExecPriority.low).whenComplete(
      () {
        if (identical(_inFlightUpdateChecks[session.connectionId], check)) {
          _inFlightUpdateChecks.remove(session.connectionId);
        }
      },
    );
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
  }) async {
    final cliRuntimes = await Future.wait(
      agentCliRuntimeDefinitions.map(
        (definition) => inspect(session, definition, priority: priority),
      ),
    );
    final cliByTool = {
      for (final runtime in cliRuntimes) ?runtime.definition.tool: runtime,
    };
    final acpRuntimes = await Future.wait(
      agentAcpRuntimeDefinitions.map((definition) {
        final shared = definition.sharesCliInstallation
            ? cliByTool[definition.tool]
            : null;
        return shared == null
            ? inspect(session, definition, priority: priority)
            : Future.value(_copyRuntimeInfo(shared, definition));
      }),
    );
    final runtimes = <AgentRuntimeInfo>[...cliRuntimes, ...acpRuntimes];
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
      );
      final path = _markerValue(probeOutput.output, _pathMarker);
      final installed = parseAgentVersion(
        _markerValue(probeOutput.output, _versionMarker) ?? '',
      );
      if (path == null) {
        return AgentRuntimeInfo(
          definition: definition,
          status: AgentRuntimeStatus.notInstalled,
          message: definition.supportsManagedInstall
              ? null
              : 'Install this tool using its official installer.',
        );
      }
      var source = _detectionSourceFromPath(path);
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
      String? latest;
      try {
        latest = await _readLatestVersion(
          session,
          definition,
          priority: priority,
        );
      } on Object {
        // An offline registry must not hide an installed runtime.
      }
      final hasUpdate =
          installed != null &&
          latest != null &&
          compareAgentVersions(installed, latest) < 0;
      final managed =
          source == 'Homebrew' || source == 'npm global' || source == 'pipx';
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
    } on Object catch (error) {
      return AgentRuntimeInfo(
        definition: definition,
        status: AgentRuntimeStatus.failed,
        message: error.toString(),
      );
    }
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

AgentRuntimeInfo _copyRuntimeInfo(
  AgentRuntimeInfo source,
  AgentRuntimeDefinition definition,
) => AgentRuntimeInfo(
  definition: definition,
  status: source.status,
  installedVersion: source.installedVersion,
  latestVersion: source.latestVersion,
  executablePath: source.executablePath,
  detectionSource: source.detectionSource,
  managedByPackageManager: source.managedByPackageManager,
  message: source.message,
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

/// Builds a non-disruptive executable and version probe for the remote OS.
String buildAgentProbeCommand(
  AgentRuntimeDefinition definition, {
  required bool windows,
}) {
  final names = definition.executableNames;
  if (windows) {
    final quotedNames = names.map(powerShellSingleQuote).join(',');
    final quotedArgs = definition.versionArguments
        .map(powerShellSingleQuote)
        .join(',');
    final body = [
      powerShellProfilePathPreamble,
      '\$__flNames=@($quotedNames);',
      '\$__flArgs=@($quotedArgs);',
      r'foreach($__flName in $__flNames){',
      r'$__flCommand=Get-Command $__flName -ErrorAction SilentlyContinue | Select-Object -First 1;',
      r'if($null -eq $__flCommand){continue};',
      '[void]\$__flOut.AppendLine(${powerShellSingleQuote(_pathMarker)} + \$__flCommand.Source);',
      r'$__flVersion=(& $__flCommand.Source @__flArgs 2>&1 | Select-Object -First 4 | ForEach-Object {$_.ToString()}) -join " ";',
      '[void]\$__flOut.AppendLine(${powerShellSingleQuote(_versionMarker)} + \$__flVersion);',
      'break}',
    ].join();
    return buildWindowsPowerShellCommand(powerShellUtf8OutputScript(body));
  }
  final candidates = names.map(_shellQuote).join(' ');
  final args = definition.versionArguments.map(_shellQuote).join(' ');
  return '$_profilePrefix'
      'for candidate in $candidates; do '
      r'resolved=$(command -v "$candidate" 2>/dev/null || true); '
      r'[ -z "$resolved" ] && continue; '
      'printf ${_shellQuote('$_pathMarker%s\\n')} "\$resolved"; '
      'version_output=\$("\$resolved" $args 2>&1 | head -n 4 | tr ${_shellQuote(r'\r\n')} ${_shellQuote('  ')}); '
      'printf ${_shellQuote('$_versionMarker%s\\n')} "\$version_output"; '
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
