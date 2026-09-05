// Generated POSIX and PowerShell fragments intentionally mix raw and interpolated strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings, use_raw_strings

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_launch_preset.dart';
import '../models/agent_runtime_info.dart';
import '../models/monetization.dart';
import 'agent_session_discovery_service.dart';
import 'diagnostics_log_service.dart';
import 'monetization_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'windows_remote_powershell.dart';

const _posixVersionRunner = r'''
__fl_agent_version() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 5 "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e '$t=shift; alarm $t; exec @ARGV' 5 "$@"
  else
    return 124
  fi
}
''';
const _profilePrefix =
    r'export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; '
    r'__fl_profile_path=$( set +e; . ~/.profile >/dev/null 2>&1 || true; . ~/.bash_profile >/dev/null 2>&1 || true; . ~/.zprofile >/dev/null 2>&1 || true; if [ "${SHELL##*/}" = zsh ]; then . ~/.zshrc >/dev/null 2>&1 || true; elif [ "${SHELL##*/}" = bash ]; then . ~/.bashrc >/dev/null 2>&1 || true; fi; printf "%s" "$PATH" ) || true; '
    r'[ -n "$__fl_profile_path" ] && export PATH="$__fl_profile_path:$PATH"; unset __fl_profile_path; '
    r'export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; ';
const _pathMarker = '__monkeyssh_agent_path__=';
const _versionMarker = '__monkeyssh_agent_version__=';
const _repairMarker = '__monkeyssh_agent_repair__';
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
    executableNames: ['agy-acp', 'antigravity-acp', 'npx'],
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

/// ACP adapters that require an installation separate from their agent CLI.
final agentStandaloneAcpRuntimeDefinitions =
    List<AgentRuntimeDefinition>.unmodifiable(
      agentAcpRuntimeDefinitions.where(
        (definition) => !definition.sharesCliInstallation,
      ),
    );

/// All runtimes that need a distinct management row.
final agentRuntimeDefinitions = List<AgentRuntimeDefinition>.unmodifiable([
  ...agentCliRuntimeDefinitions,
  ...agentStandaloneAcpRuntimeDefinitions,
]);

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

// Repair the package behind the detected launcher, not a different npm prefix.
// Bun and npm installations can coexist, with Bun's broken shim first on PATH.
const _openCodeRepairScript = '''
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const launcher = fs.realpathSync(process.argv[1]);
let dir = path.dirname(launcher);
let root;
while (true) {
  const candidates = [dir];
  if (process.platform === 'win32') candidates.push(path.join(dir, 'node_modules', 'opencode-ai'));
  for (const candidate of candidates) {
    try {
      const pkg = JSON.parse(fs.readFileSync(path.join(candidate, 'package.json'), 'utf8'));
      if (pkg.name === 'opencode-ai' && fs.existsSync(path.join(candidate, 'postinstall.mjs'))) {
        root = candidate;
        break;
      }
    } catch {}
  }
  if (root || path.dirname(dir) === dir) break;
  dir = path.dirname(dir);
}
if (!root) {
  console.error('Cannot locate the OpenCode package behind the detected launcher. Reinstall it with its original package manager.');
  process.exit(1);
}
const result = cp.spawnSync(process.execPath, [path.join(root, 'postinstall.mjs')], {
  cwd: root, stdio: 'inherit', windowsHide: true,
});
process.exit(result.status === null ? 1 : result.status);
''';

/// Builds the remote install or update command for [definition].
String? buildAgentInstallCommand(
  AgentRuntimeDefinition definition, {
  required bool windows,
  required bool update,
  bool repair = false,
  String? detectionSource,
  String? executablePath,
}) {
  if (repair && definition.id == 'cli:opencode' && executablePath != null) {
    if (windows) {
      return buildWindowsPowerShellCommand(
        '$powerShellProfilePathPreamble& node -e '
        '${powerShellSingleQuote(_openCodeRepairScript)} '
        '${powerShellSingleQuote(executablePath)}; exit \u0024LASTEXITCODE',
      );
    }
    return '${_profilePrefix}node -e ${_shellQuote(_openCodeRepairScript)} '
        '${_shellQuote(executablePath)}';
  }
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
        if (repair) ...[
          '& npm uninstall -g $quotedPackage;',
          r'if($LASTEXITCODE -ne 0){exit $LASTEXITCODE};',
        ],
        '& npm install -g --foreground-scripts --ignore-scripts=false $quotedLatest;',
        r'exit $LASTEXITCODE',
      ].join(),
      AgentPackageRegistry.pipx => [
        powerShellProfilePathPreamble,
        'if(Get-Command pipx -ErrorAction SilentlyContinue){',
        if (repair)
          '& pipx reinstall $quotedPackage;'
        else if (update)
          '& pipx upgrade $quotedPackage;'
        else
          '& pipx install $quotedPackage;',
        r'if($LASTEXITCODE -eq 0){exit 0}};',
        if (repair)
          '& py -m pip install --user --upgrade --force-reinstall $quotedPackage;'
        else if (update)
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
      repair
          ? '$_profilePrefix npm uninstall -g ${_shellQuote(package)} && npm install -g --foreground-scripts --ignore-scripts=false ${_shellQuote(package)}@latest'
          : '$_profilePrefix npm install -g --foreground-scripts --ignore-scripts=false ${_shellQuote(package)}@latest',
    AgentPackageRegistry.pipx =>
      repair
          ? '$_profilePrefix pipx reinstall ${_shellQuote(package)} || python3 -m pip install --user --upgrade --force-reinstall ${_shellQuote(package)}'
          : update
          ? '$_profilePrefix pipx upgrade ${_shellQuote(package)} || python3 -m pip install --user --upgrade ${_shellQuote(package)}'
          : '$_profilePrefix pipx install ${_shellQuote(package)} || python3 -m pip install --user ${_shellQuote(package)}',
    null => null,
  };
}

/// Inspects and manages coding-agent runtimes over non-interactive SSH exec.
class AgentManagementService {
  /// Creates the service.
  AgentManagementService(
    this._discovery, {
    required Future<bool> Function() canManageAgents,
  }) : _canManageAgents = canManageAgents;

  final Future<bool> Function() _canManageAgents;

  static const _updateCheckTtl = Duration(minutes: 15);

  final AgentSessionDiscoveryService _discovery;
  final Map<int, ({DateTime checkedAt, List<AgentRuntimeInfo> runtimes})>
  _runtimeCache = {};
  final Map<int, Future<List<AgentRuntimeInfo>>> _inFlightUpdateChecks = {};

  /// Returns cached update information or probes the active host.
  /// Periodic checks bypass the cache with [forceRefresh], but share in-flight work.
  Future<List<AgentRuntimeInfo>> checkForUpdates(
    SshSession session, {
    bool forceRefresh = false,
  }) async {
    if (!await _canManageAgents()) return const [];
    final cached = _runtimeCache[session.connectionId];
    if (!forceRefresh &&
        cached != null &&
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
    if (!await _canManageAgents()) return const [];
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
      if (includeAdapters) ...agentStandaloneAcpRuntimeDefinitions,
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
        timeout: const Duration(seconds: 8),
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
          keepPartialOutputOnTimeout: true,
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
    final runtimes = <AgentRuntimeInfo>[];
    for (final definition in agentCliRuntimeDefinitions) {
      final runtime = byId[definition.id];
      if (runtime == null) continue;
      runtimes.add(runtime);
    }
    if (includeAdapters) {
      for (final definition in agentStandaloneAcpRuntimeDefinitions) {
        final runtime = byId[definition.id];
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
    if (!await _canManageAgents()) {
      return AgentRuntimeInfo(
        definition: definition,
        status: AgentRuntimeStatus.unavailable,
        message: 'Agent Management requires MonkeySSH Pro.',
      );
    }
    try {
      final probeOutput = await _run(
        session,
        buildAgentProbeCommand(definition, windows: session.remoteIsWindows),
        priority: priority,
        timeout: const Duration(seconds: 8),
      );
      final snapshot = AgentProbeSnapshot(
        executablePath: _markerValue(probeOutput.output, _pathMarker),
        versionOutput: _markerValue(probeOutput.output, _versionMarker),
        needsRepair: const LineSplitter()
            .convert(probeOutput.output)
            .map((line) => line.trim())
            .contains(_repairMarker),
      );
      AgentMetadataSnapshot? metadata;
      if (snapshot.executablePath != null) {
        try {
          final metadataOutput = await _run(
            session,
            buildAgentMetadataProbeCommand([
              definition,
            ], windows: session.remoteIsWindows),
            priority: priority,
            timeout: const Duration(seconds: 10),
            keepPartialOutputOnTimeout: true,
          );
          metadata = parseAgentMetadataProbeOutput(
            metadataOutput.output,
          )[definition.id];
        } on Object {
          // Registry failures must not erase a working executable's version.
        }
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
    if (snapshot.needsRepair) {
      return AgentRuntimeInfo(
        definition: definition,
        status: AgentRuntimeStatus.needsRepair,
        executablePath: path,
        detectionSource: _detectionSourceFromPath(path),
        managedByPackageManager: definition.supportsManagedInstall,
        message:
            'Required setup scripts did not run. Repair the installation before launching this agent.',
      );
    }
    var source = metadata?.detectionSource;
    source ??=
        definition.id == 'acp:antigravity' && _executableBasename(path) == 'npx'
        ? 'npx on demand'
        : _detectionSourceFromPath(path);
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
    if (!await _canManageAgents()) {
      return const AgentRuntimeActionResult(
        succeeded: false,
        output: 'Agent Management requires MonkeySSH Pro.',
      );
    }
    final command = buildAgentInstallCommand(
      definition,
      windows: session.remoteIsWindows,
      update: update,
      repair: current?.status == AgentRuntimeStatus.needsRepair,
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
    final repairing = current?.status == AgentRuntimeStatus.needsRepair;
    DiagnosticsLogService.instance.info(
      'agent.management',
      'action_start',
      fields: {
        'connectionId': session.connectionId,
        'agentId': definition.id,
        'update': update,
        'repair': repairing,
        'registry': definition.registry?.name ?? 'none',
      },
    );
    late AgentRuntimeActionResult result;
    try {
      result = await _run(session, command, onOutput: onOutput, timeout: null);
      if (result.succeeded && definition.kind == AgentRuntimeKind.cli) {
        final verified = await inspect(session, definition);
        final healthy =
            (verified.status == AgentRuntimeStatus.installed ||
                verified.status == AgentRuntimeStatus.updateAvailable) &&
            verified.installedVersion != null;
        DiagnosticsLogService.instance.info(
          'agent.management',
          'action_verification',
          fields: {
            'connectionId': session.connectionId,
            'agentId': definition.id,
            'status': verified.status.name,
            'hasVersion': verified.installedVersion != null,
            'success': healthy,
          },
        );
        if (!healthy) {
          result = AgentRuntimeActionResult(
            succeeded: false,
            exitCode: result.exitCode,
            output:
                '${result.output}\nThe command finished, but '
                '${definition.label} could not be verified. '
                '${verified.message ?? 'Re-check the detected installation before launching it.'}',
          );
        }
      }

      DiagnosticsLogService.instance.info(
        'agent.management',
        'action_complete',
        fields: {
          'connectionId': session.connectionId,
          'agentId': definition.id,
          'update': update,
          'repair': repairing,
          'success': result.succeeded,
          'exitCode': result.exitCode ?? -1,
        },
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'agent.management',
        'action_failed',
        fields: {
          'connectionId': session.connectionId,
          'agentId': definition.id,
          'update': update,
          'repair': repairing,
          'errorType': error.runtimeType,
        },
      );
      rethrow;
    }
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
    bool keepPartialOutputOnTimeout = false,
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
        try {
          await completion.timeout(timeout);
        } on TimeoutException {
          if (!keepPartialOutputOnTimeout) rethrow;
        }
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
  const AgentProbeSnapshot({
    this.executablePath,
    this.versionOutput,
    this.needsRepair = false,
  });

  /// Resolved remote executable path.
  final String? executablePath;

  /// Raw normalized output from the runtime's version command.
  final String? versionOutput;

  /// Whether the executable reports that required install scripts were skipped.
  final bool needsRepair;
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
  var needsRepair = false;
  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trim();
    if (line.startsWith(_runtimeMarker)) {
      if (id != null) {
        snapshots[id] = AgentProbeSnapshot(
          executablePath: path == null || path.isEmpty ? null : path,
          versionOutput: version == null || version.isEmpty ? null : version,
          needsRepair: needsRepair,
        );
      }
      id = line.substring(_runtimeMarker.length);
      path = null;
      version = null;
      needsRepair = false;
    } else if (id != null && line.startsWith(_pathMarker)) {
      path = line.substring(_pathMarker.length).trim();
    } else if (id != null && line.startsWith(_versionMarker)) {
      version = line.substring(_versionMarker.length).trim();
    } else if (id != null && line == _repairMarker) {
      needsRepair = true;
    } else if (id != null && line == _runtimeEndMarker) {
      snapshots[id] = AgentProbeSnapshot(
        executablePath: path == null || path.isEmpty ? null : path,
        versionOutput: version == null || version.isEmpty ? null : version,
        needsRepair: needsRepair,
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

  final command = StringBuffer(_posixVersionRunner)
    ..write(
      r'__fl_probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/monkeyssh-agent.XXXXXX") || exit 1; ',
    )
    ..write('__fl_probe_pids=; ');
  for (var index = 0; index < definitions.length; index += 1) {
    final definition = definitions[index];
    command
      ..write('( printf ${_shellQuote('$_runtimeMarker%s\\n')} ')
      ..write('${_shellQuote(definition.id)}; ')
      ..write(_buildPosixProbeBody(definition))
      ..write('; printf ${_shellQuote('$_runtimeEndMarker\\n')} ) ')
      ..write('> "\$__fl_probe_dir/$index" 2>&1 & ')
      ..write('__fl_probe_pids="\$__fl_probe_pids \$!"; ');
  }
  command.write(
    r'for __fl_pid in $__fl_probe_pids; do wait "$__fl_pid" 2>/dev/null || true; done; ',
  );
  for (var index = 0; index < definitions.length; index += 1) {
    command.write('cat "\$__fl_probe_dir/$index"; ');
  }
  command.write(r'rm -rf "$__fl_probe_dir"; ');
  return '${_profilePrefix}sh -c ${_shellQuote(command.toString())}';
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
  return '${_profilePrefix}sh -c '
      '${_shellQuote('$_posixVersionRunner${_buildPosixProbeBody(definition)}')}';
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
  final versionArguments = definition.versionArguments
      .map(_shellQuote)
      .join(' ');
  final versionProbe = definition.kind == AgentRuntimeKind.cli
      ? '__fl_version_file=\$(mktemp "\u0024{TMPDIR:-/tmp}/monkeyssh-version.XXXXXX" 2>/dev/null || true); '
            'if [ -n "\$__fl_version_file" ]; then '
            'version_output=; '
            'if __fl_agent_version "\$resolved" $versionArguments >"\$__fl_version_file" 2>&1; then '
            'version_output=\$(head -n 4 "\$__fl_version_file" | tr ${_shellQuote(r'\r\n')} ${_shellQuote('  ')}); '
            'elif grep -Eiq ${_shellQuote('postinstall (script )?(was )?not run|--ignore-scripts')} "\$__fl_version_file"; then '
            'printf ${_shellQuote('$_repairMarker\n')}; '
            'fi; '
            'rm -f "\$__fl_version_file"; '
            'printf ${_shellQuote('$_versionMarker%s\\n')} "\$version_output"; '
            'fi; '
      : '';
  return 'for candidate in $candidates; do '
      r'resolved=$(command -v "$candidate" 2>/dev/null || true); '
      r'[ -z "$resolved" ] && continue; '
      'printf ${_shellQuote('$_pathMarker%s\\n')} "\$resolved"; '
      '$versionProbe'
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

String _executableBasename(String path) =>
    path.replaceAll('\\', '/').split('/').last.toLowerCase();

String _detectionSourceFromPath(String path) {
  final normalized = path.toLowerCase();
  if (normalized.contains('/.cargo/')) return 'Cargo';
  return 'PATH';
}

String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Provider for [AgentManagementService].
final agentManagementServiceProvider = Provider<AgentManagementService>(
  (ref) => AgentManagementService(
    ref.watch(agentSessionDiscoveryServiceProvider),
    canManageAgents: () => ref
        .read(monetizationServiceProvider)
        .canUseFeature(MonetizationFeature.agentManagement),
  ),
);
