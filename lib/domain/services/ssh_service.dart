import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/known_hosts_repository.dart';
import '../models/terminal_theme.dart';
import 'background_ssh_service.dart';
import 'clipboard_sharing_service.dart';
import 'diagnostics_log_service.dart';
import 'host_key_prompt_handler_provider.dart';
import 'host_key_verification.dart';
import 'ssh_exec_queue.dart';
import 'terminal_hyperlink_tracker.dart';
import 'wifi_network_service.dart';

/// Current terminal dimensions used to answer terminal size queries.
typedef TerminalWindowMetrics = ({
  int columns,
  int rows,
  int pixelWidth,
  int pixelHeight,
});

/// Terminal mode state used to answer DECRQM mode-status queries.
typedef TerminalControlModeState = ({
  bool reportFocusMode,
  bool bracketedPasteMode,
  bool colorSchemeUpdatesMode,
  bool isUsingAltBuffer,
  bool mouseTrackingMode,
  bool mouseDragTrackingMode,
  bool mouseMoveTrackingMode,
  bool sgrMouseReportMode,
});

/// Unwraps tmux DCS passthrough sequences from shell output.
///
/// Apps running inside tmux wrap terminal queries as
/// `DCS tmux; <escaped sequence> ST`. The inner ESC bytes are doubled by tmux;
/// this returns a stream that xterm can parse normally while preserving split
/// passthrough sequences across chunks.
({String output, String pendingInput}) unwrapTerminalTmuxPassthroughSequences({
  required String input,
  required String pendingInput,
}) {
  final combinedInput = pendingInput + input;
  final output = StringBuffer();
  var cursor = 0;

  while (cursor < combinedInput.length) {
    final startIndex = combinedInput.indexOf(
      _terminalTmuxPassthroughStart,
      cursor,
    );
    if (startIndex == -1) {
      output.write(combinedInput.substring(cursor));
      final outputValue = output.toString();
      final pendingSuffix = _terminalTmuxPassthroughPendingSuffix(outputValue);
      if (pendingSuffix.isEmpty) {
        return (output: outputValue, pendingInput: '');
      }
      return (
        output: outputValue.substring(
          0,
          outputValue.length - pendingSuffix.length,
        ),
        pendingInput: pendingSuffix,
      );
    }

    output.write(combinedInput.substring(cursor, startIndex));
    final payloadStart = startIndex + _terminalTmuxPassthroughStart.length;
    final endIndex = combinedInput.indexOf(
      _terminalStringTerminator,
      payloadStart,
    );
    if (endIndex == -1) {
      return (
        output: output.toString(),
        pendingInput: combinedInput.substring(startIndex),
      );
    }

    output.write(
      combinedInput
          .substring(payloadStart, endIndex)
          .replaceAll(_escapedTerminalEscape, _terminalEscape),
    );
    cursor = endIndex + _terminalStringTerminator.length;
  }

  return (output: output.toString(), pendingInput: '');
}

/// Builds responses for terminal window/cell size and theme reports in shell
/// output.
///
/// [pendingInput] should be the pending suffix returned by the previous call,
/// so split CSI sequences can be recognized across UTF-8 stream chunks.
({String? response, String pendingInput})
buildTerminalWindowControlQueryResponses({
  required String input,
  required String pendingInput,
  required TerminalWindowMetrics? metrics,
  TerminalControlModeState? modeState,
  TerminalThemeData? theme,
}) {
  final combinedInput = pendingInput + input;
  final responses = StringBuffer();

  for (final match in _terminalWindowQueryPattern.allMatches(combinedInput)) {
    final params = match.group(1) ?? '';
    final primaryParam = params.split(';').first;
    final response = _buildTerminalWindowQueryResponse(primaryParam, metrics);
    if (response != null) {
      responses.write(response);
    }
  }

  for (final match in _terminalModeReportQueryPattern.allMatches(
    combinedInput,
  )) {
    final params = match.group(1)?.split(';') ?? const <String>[];
    for (final param in params) {
      final mode = int.tryParse(param);
      if (mode == null) {
        continue;
      }
      final response = _buildTerminalModeReportResponse(mode, modeState);
      if (response != null) {
        responses.write(response);
      }
    }
  }

  if (theme != null && _terminalThemeModeQueryPattern.hasMatch(combinedInput)) {
    responses.write(buildTerminalThemeModeReport(isDark: theme.isDark));
  }

  final response = responses.isEmpty ? null : responses.toString();
  return (
    response: response,
    pendingInput: _terminalControlQueryPendingSuffix(combinedInput),
  );
}

/// Extracts terminal color-scheme update mode changes from shell output.
///
/// Some TUIs enable DEC private mode 2031 to request a report when the
/// terminal switches between light and dark color schemes. xterm.dart does not
/// currently model that mode, so MonkeySSH tracks it while scanning the same
/// shell output used for other terminal control queries.
({bool? colorSchemeUpdatesMode, String pendingInput})
extractTerminalControlModeUpdates({
  required String input,
  required String pendingInput,
}) {
  final combinedInput = pendingInput + input;
  bool? colorSchemeUpdatesMode;

  for (final match in _terminalPrivateModeSetResetPattern.allMatches(
    combinedInput,
  )) {
    final params = match.group(1)?.split(';') ?? const <String>[];
    if (!params.contains('2031')) {
      continue;
    }
    colorSchemeUpdatesMode = match.group(2) == 'h';
  }

  return (
    colorSchemeUpdatesMode: colorSchemeUpdatesMode,
    pendingInput: _terminalControlQueryPendingSuffix(combinedInput),
  );
}

/// Normalizes terminal-generated output before it is sent to the remote shell.
///
/// xterm.dart currently emits cursor-position reports using its internal
/// zero-based cursor coordinates. The terminal DSR wire protocol is one-based,
/// and TUIs such as Codex can stall or mis-detect terminal state after receiving
/// `CSI 0;0 R`.
String normalizeTerminalOutputForRemoteShell(String data) =>
    data.replaceAllMapped(_terminalCursorPositionReportPattern, (match) {
      final row = int.parse(match.group(1)!);
      final column = int.parse(match.group(2)!);
      return '\x1b[${row + 1};${column + 1}R';
    });

final _terminalWindowQueryPattern = RegExp(r'\x1b\[([0-9;?]*)t');
final _terminalModeReportQueryPattern = RegExp(r'\x1b\[\?([0-9;]+)\$p');
final _terminalThemeModeQueryPattern = RegExp(r'\x1b\[\?996n');
final _terminalControlQueryPrefixPattern = RegExp(r'^\x1b(?:$|\[[0-9;?\$]*)$');
final _terminalPrivateModeSetResetPattern = RegExp(r'\x1b\[\?([0-9;]+)([hl])');
final _terminalCursorPositionReportPattern = RegExp(
  r'\x1b\[([0-9]+);([0-9]+)R',
);

String? _buildTerminalWindowQueryResponse(
  String primaryParam,
  TerminalWindowMetrics? metrics,
) {
  if (!_hasValidTerminalWindowMetrics(metrics)) {
    return null;
  }

  final validMetrics = metrics!;
  switch (primaryParam) {
    case '14':
      return '\x1b[4;${validMetrics.pixelHeight};${validMetrics.pixelWidth}t';
    case '16':
      final cellWidth = (validMetrics.pixelWidth / validMetrics.columns)
          .round();
      final cellHeight = (validMetrics.pixelHeight / validMetrics.rows).round();
      if (cellWidth < 1 || cellHeight < 1) {
        return null;
      }
      return '\x1b[6;$cellHeight;${cellWidth}t';
    default:
      return null;
  }
}

String? _buildTerminalModeReportResponse(
  int mode,
  TerminalControlModeState? modeState,
) {
  if (modeState == null) {
    return switch (mode) {
      1016 ||
      2026 ||
      2027 ||
      2031 => _formatTerminalModeReport(mode, _terminalModeNotRecognized),
      _ => null,
    };
  }

  return switch (mode) {
    1000 => _formatTerminalModeReport(
      mode,
      modeState.mouseTrackingMode ? _terminalModeSet : _terminalModeReset,
    ),
    1002 => _formatTerminalModeReport(
      mode,
      modeState.mouseDragTrackingMode ? _terminalModeSet : _terminalModeReset,
    ),
    1003 => _formatTerminalModeReport(
      mode,
      modeState.mouseMoveTrackingMode ? _terminalModeSet : _terminalModeReset,
    ),
    1004 => _formatTerminalModeReport(
      mode,
      modeState.reportFocusMode ? _terminalModeSet : _terminalModeReset,
    ),
    1006 => _formatTerminalModeReport(
      mode,
      modeState.sgrMouseReportMode ? _terminalModeSet : _terminalModeReset,
    ),
    1049 => _formatTerminalModeReport(
      mode,
      modeState.isUsingAltBuffer ? _terminalModeSet : _terminalModeReset,
    ),
    2004 => _formatTerminalModeReport(
      mode,
      modeState.bracketedPasteMode ? _terminalModeSet : _terminalModeReset,
    ),
    2031 => _formatTerminalModeReport(
      mode,
      modeState.colorSchemeUpdatesMode ? _terminalModeSet : _terminalModeReset,
    ),
    1016 ||
    2026 ||
    2027 => _formatTerminalModeReport(mode, _terminalModeNotRecognized),
    _ => null,
  };
}

const _terminalModeNotRecognized = 0;
const _terminalModeSet = 1;
const _terminalModeReset = 2;

const _terminalEscape = '\x1b';
const _escapedTerminalEscape = '$_terminalEscape$_terminalEscape';
const _terminalStringTerminator = '$_terminalEscape\\';
const _terminalTmuxPassthroughStart = '${_terminalEscape}Ptmux;';

String _formatTerminalModeReport(int mode, int status) =>
    '\x1b[?$mode;$status\$y';

String _terminalTmuxPassthroughPendingSuffix(String input) {
  final maxSuffixLength =
      input.length < _terminalTmuxPassthroughStart.length - 1
      ? input.length
      : _terminalTmuxPassthroughStart.length - 1;
  for (var length = maxSuffixLength; length > 0; length -= 1) {
    final suffix = input.substring(input.length - length);
    if (_terminalTmuxPassthroughStart.startsWith(suffix)) {
      return suffix;
    }
  }
  return '';
}

bool _hasValidTerminalWindowMetrics(TerminalWindowMetrics? metrics) =>
    metrics != null &&
    metrics.columns > 0 &&
    metrics.rows > 0 &&
    metrics.pixelWidth > 0 &&
    metrics.pixelHeight > 0;

String _terminalControlQueryPendingSuffix(String input) {
  final start = input.length > 16 ? input.length - 16 : 0;
  for (var index = start; index < input.length; index += 1) {
    final suffix = input.substring(index);
    if (_terminalControlQueryPrefixPattern.hasMatch(suffix)) {
      return suffix;
    }
  }
  return '';
}

/// Connection state for an SSH session.
enum SshConnectionState {
  /// Not connected.
  disconnected,

  /// Connecting to host.
  connecting,

  /// Authenticating with host.
  authenticating,

  /// Connected and authenticated.
  connected,

  /// Connection error occurred.
  error,

  /// Reconnecting after disconnect.
  reconnecting,
}

/// Shell integration state reported through terminal metadata sequences.
enum TerminalShellStatus {
  /// The shell is displaying a prompt and ready for the next command.
  prompt,

  /// The user is composing or editing the current command line.
  editingCommand,

  /// A submitted command is currently running.
  runningCommand,
}

/// Parses an OSC 7 working-directory URI from private terminal metadata.
Uri? parseTerminalWorkingDirectoryUri(List<String> args) {
  if (args.isEmpty) {
    return null;
  }

  final candidate = args.join(';').trim();
  if (candidate.isEmpty) {
    return null;
  }

  final uri = Uri.tryParse(candidate);
  if (uri == null || !uri.hasScheme) {
    return null;
  }

  return uri;
}

/// Resolves the decoded directory path from a terminal working-directory URI.
String? resolveTerminalWorkingDirectoryPath(Uri? workingDirectory) {
  if (workingDirectory == null) {
    return null;
  }

  final decodedPath = () {
    try {
      return Uri.decodeComponent(workingDirectory.path).trim();
    } on FormatException {
      return workingDirectory.path.trim();
    }
  }();
  if (decodedPath.isNotEmpty) {
    return decodedPath;
  }

  final fallback = workingDirectory.toString().trim();
  return fallback.isEmpty ? null : fallback;
}

/// Formats a terminal working-directory URI for compact UI display.
String? formatTerminalWorkingDirectoryLabel(Uri? workingDirectory) {
  final path = resolveTerminalWorkingDirectoryPath(workingDirectory);
  if (path == null) {
    return null;
  }

  final host = workingDirectory?.host.trim() ?? '';
  return host.isEmpty ? path : '$host:$path';
}

/// Applies an OSC 133 shell integration update to the current shell state.
({TerminalShellStatus? status, int? lastExitCode})
applyTerminalShellIntegrationOsc(
  List<String> args, {
  required TerminalShellStatus? previousStatus,
  required int? previousExitCode,
}) {
  if (args.isEmpty) {
    return (status: previousStatus, lastExitCode: previousExitCode);
  }

  switch (args.first) {
    case 'A':
      return (
        status: TerminalShellStatus.prompt,
        lastExitCode: previousExitCode,
      );
    case 'B':
      return (status: TerminalShellStatus.editingCommand, lastExitCode: null);
    case 'C':
      return (status: TerminalShellStatus.runningCommand, lastExitCode: null);
    case 'D':
      return (
        status: TerminalShellStatus.prompt,
        lastExitCode: args.length > 1
            ? int.tryParse(args[1]) ?? previousExitCode
            : previousExitCode,
      );
    default:
      return (status: previousStatus, lastExitCode: previousExitCode);
  }
}

/// Formats a shell integration state for compact UI display.
String? describeTerminalShellStatus(
  TerminalShellStatus? status, {
  int? lastExitCode,
}) {
  final exitLabel = lastExitCode != null && lastExitCode != 0
      ? 'Exit $lastExitCode'
      : null;

  switch (status) {
    case TerminalShellStatus.prompt:
      return exitLabel ?? 'Prompt';
    case TerminalShellStatus.editingCommand:
      return 'Editing command';
    case TerminalShellStatus.runningCommand:
      return 'Running command';
    case null:
      return exitLabel;
  }
}

/// Configuration for an SSH connection.
class SshConnectionConfig {
  /// Creates a new [SshConnectionConfig].
  const SshConnectionConfig({
    required this.hostname,
    required this.port,
    required this.username,
    this.password,
    this.privateKey,
    this.passphrase,
    this.identityKeys,
    this.jumpHost,
    this.keepAliveInterval = const Duration(seconds: 30),
    this.connectionTimeout = const Duration(seconds: 30),
  });

  /// Creates config from a Host entity.
  factory SshConnectionConfig.fromHost(
    Host host, {
    SshKey? key,
    List<SshKey>? identityKeys,
    SshConnectionConfig? jumpHostConfig,
  }) => SshConnectionConfig(
    hostname: host.hostname,
    port: host.port,
    username: host.username,
    password: host.password,
    privateKey: key?.privateKey,
    passphrase: key?.passphrase,
    identityKeys: identityKeys,
    jumpHost: jumpHostConfig,
  );

  /// Hostname or IP address.
  final String hostname;

  /// SSH port.
  final int port;

  /// Username for authentication.
  final String username;

  /// Password for authentication (if using password auth).
  final String? password;

  /// Private key content (if using key auth).
  final String? privateKey;

  /// Passphrase for private key (if encrypted).
  final String? passphrase;

  /// Candidate keys to try automatically, ordered by key ID.
  final List<SshKey>? identityKeys;

  /// Jump host configuration for proxy connections.
  final SshConnectionConfig? jumpHost;

  /// Keep-alive interval.
  final Duration keepAliveInterval;

  /// Connection timeout.
  final Duration connectionTimeout;
}

/// Result of an SSH connection attempt.
class SshConnectionResult {
  /// Creates a new [SshConnectionResult].
  const SshConnectionResult({
    required this.success,
    this.error,
    this.client,
    this.connectionId,
    this.reusedConnection = false,
    this.dependentClients = const <SSHClient>[],
  });

  /// Whether connection was successful.
  final bool success;

  /// Error message if connection failed.
  final String? error;

  /// The SSH client if connected.
  final SSHClient? client;

  /// The active connection ID when a session is available.
  final int? connectionId;

  /// Whether an existing connection was reused.
  final bool reusedConnection;

  /// Additional SSH clients that must be closed with [client].
  final List<SSHClient> dependentClients;

  /// Closes [client] and any dependent jump-host clients.
  Future<void> closeAll() async {
    client?.close();
    for (final dependentClient in dependentClients) {
      dependentClient.close();
    }
  }
}

/// Progress callback for long-running SSH connection attempts.
typedef ConnectionProgressCallback =
    void Function(ConnectionProgressUpdate update);

/// Connects a raw SSH socket for the requested host.
typedef SshSocketConnector =
    Future<SSHSocket> Function(String host, int port, {Duration? timeout});

/// Creates an [SSHClient] for a prepared socket.
typedef SshClientFactory =
    SSHClient Function(
      SSHSocket socket, {
      required String username,
      SSHHostkeyVerifyHandler? onVerifyHostKey,
      SSHPasswordRequestHandler? onPasswordRequest,
      List<SSHKeyPair>? identities,
      Duration? keepAliveInterval,
    });

/// Exposes the raw SSH host key bytes observed during the handshake.
abstract interface class HostKeySource {
  /// Completes with the raw SSH wire-format host key.
  Future<Uint8List> get hostKeyBytes;
}

/// Captures a host key from fragmented SSH handshake chunks using the real
/// socket wrapper and parser path.
@visibleForTesting
Future<Uint8List> captureHostKeyFromHandshakeChunksForTesting(
  Iterable<Uint8List> chunks,
) async {
  final capturingSocket = _HostKeyCapturingSocket(
    _FiniteChunkSshSocket(chunks),
  );
  unawaited(capturingSocket.stream.drain<void>());
  return capturingSocket.hostKeyBytes;
}

/// A single progress update emitted while an SSH connection is being created.
class ConnectionProgressUpdate {
  /// Creates a [ConnectionProgressUpdate].
  const ConnectionProgressUpdate({required this.state, required this.message});

  /// The current connection phase.
  final SshConnectionState state;

  /// Human-readable status text for the current phase.
  final String message;
}

/// Host-level connection attempt state for live progress UI.
class ConnectionAttemptStatus {
  /// Creates a [ConnectionAttemptStatus].
  const ConnectionAttemptStatus({
    required this.hostId,
    required this.state,
    required this.latestMessage,
    required this.logLines,
  });

  /// The host currently being connected.
  final int hostId;

  /// The latest known connection state.
  final SshConnectionState state;

  /// The newest status message shown to the user.
  final String latestMessage;

  /// Rolling log of recent connection progress messages.
  final List<String> logLines;

  /// Whether the connection attempt is still actively progressing.
  bool get isInProgress =>
      state == SshConnectionState.connecting ||
      state == SshConnectionState.authenticating ||
      state == SshConnectionState.reconnecting;
}

/// Service for managing SSH connections.
class SshService {
  /// Creates a new [SshService].
  SshService({
    this.hostRepository,
    this.keyRepository,
    this.knownHostsRepository,
    this.hostKeyPromptHandler,
    WifiNetworkService? wifiNetworkService,
    SshSocketConnector? socketConnector,
    SshClientFactory? clientFactory,
  }) : wifiNetworkService = wifiNetworkService ?? WifiNetworkService(),
       _socketConnector = socketConnector ?? _connectWithKeepAlive,
       _clientFactory = clientFactory ?? _defaultClientFactory;

  /// Number of key identities to try per SSH authentication attempt.
  ///
  /// Keeping this below common server `MaxAuthTries` defaults avoids
  /// "too many authentication failures" disconnects in Auto mode.
  static const _maxAutoKeysPerAttempt = 5;
  static const _hostKeyProbeSettleTimeout = Duration(seconds: 1);

  /// Host repository for looking up hosts.
  final HostRepository? hostRepository;

  /// Key repository for looking up keys.
  final KeyRepository? keyRepository;

  /// Repository for trusted SSH host keys.
  final KnownHostsRepository? knownHostsRepository;

  /// UI callback used for TOFU and changed-key prompts.
  final HostKeyPromptHandler? hostKeyPromptHandler;

  /// Service used to read the current Wi-Fi SSID for jump host bypass.
  final WifiNetworkService wifiNetworkService;

  final SshSocketConnector _socketConnector;
  final SshClientFactory _clientFactory;

  final Map<int, SshSession> _sessions = {};
  int _nextConnectionId = 1;

  /// Get all active sessions.
  Map<int, SshSession> get sessions => Map.unmodifiable(_sessions);

  /// All active session instances.
  Iterable<SshSession> get allSessions => _sessions.values;

  /// Connect to a host by ID.
  Future<SshConnectionResult> connectToHost(
    int hostId, {
    ConnectionProgressCallback? onProgress,
    bool useHostThemeOverrides = true,
  }) async {
    DiagnosticsLogService.instance.info(
      'ssh.connect',
      'connect_to_host_start',
      fields: {'hostId': hostId},
    );
    if (hostRepository == null) {
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_to_host_unavailable',
        fields: {'hostId': hostId, 'reason': 'missing_host_repository'},
      );
      return const SshConnectionResult(
        success: false,
        error: 'Host repository not available',
      );
    }

    final host = await hostRepository!.getById(hostId);
    if (host == null) {
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_to_host_missing_host',
        fields: {'hostId': hostId},
      );
      return const SshConnectionResult(success: false, error: 'Host not found');
    }

    List<SshKey>? cachedAutoKeys;
    var didLoadAutoKeys = false;
    Future<List<SshKey>?> loadAutoKeys() async {
      if (didLoadAutoKeys) {
        return cachedAutoKeys;
      }
      didLoadAutoKeys = true;
      if (keyRepository == null) {
        return null;
      }
      final keys = await keyRepository!.getAll();
      if (keys.isEmpty) {
        return null;
      }
      final sortedKeys = [...keys]..sort((a, b) => a.id.compareTo(b.id));
      final autoKeys = sortedKeys.length > _maxAutoKeysPerAttempt
          ? sortedKeys.take(_maxAutoKeysPerAttempt).toList(growable: false)
          : sortedKeys;
      return cachedAutoKeys = autoKeys;
    }

    // Get SSH key if explicitly selected, otherwise use auto keys.
    SshKey? key;
    List<SshKey>? identityKeys;
    if (host.keyId != null && keyRepository != null) {
      key = await keyRepository!.getById(host.keyId!);
      if (key == null && host.password == null) {
        identityKeys = await loadAutoKeys();
      }
    } else if (host.password == null) {
      identityKeys = await loadAutoKeys();
    }

    // Get jump host config if specified, unless the device is currently
    // connected to a Wi-Fi network on the host's skip list (in which case
    // the host is reachable directly).
    SshConnectionConfig? jumpHostConfig;
    if (host.jumpHostId != null) {
      var skipJumpHost = false;
      if (host.skipJumpHostOnSsids != null &&
          host.skipJumpHostOnSsids!.isNotEmpty) {
        final currentSsid = await wifiNetworkService.getCurrentSsid();
        skipJumpHost = shouldSkipJumpHostForSsid(
          currentSsid: currentSsid,
          skipJumpHostOnSsids: host.skipJumpHostOnSsids,
        );
        DiagnosticsLogService.instance.info(
          'ssh.connect',
          'jump_host_ssid_check',
          fields: {
            'hostId': hostId,
            'hasCurrentSsid': currentSsid != null,
            'skipJumpHost': skipJumpHost,
          },
        );
      }
      if (!skipJumpHost) {
        final jumpHost = await hostRepository!.getById(host.jumpHostId!);
        if (jumpHost != null) {
          SshKey? jumpKey;
          List<SshKey>? jumpIdentityKeys;
          if (jumpHost.keyId != null && keyRepository != null) {
            jumpKey = await keyRepository!.getById(jumpHost.keyId!);
            if (jumpKey == null && jumpHost.password == null) {
              jumpIdentityKeys = await loadAutoKeys();
            }
          } else if (jumpHost.password == null) {
            jumpIdentityKeys = await loadAutoKeys();
          }
          jumpHostConfig = SshConnectionConfig.fromHost(
            jumpHost,
            key: jumpKey,
            identityKeys: jumpIdentityKeys,
          );
        }
      }
    }

    final config = SshConnectionConfig.fromHost(
      host,
      key: key,
      identityKeys: identityKeys,
      jumpHostConfig: jumpHostConfig,
    );

    final result = await connect(config, onProgress: onProgress);

    if (result.success && result.client != null) {
      final connectionId = _nextConnectionId++;
      _sessions[connectionId] = SshSession(
        connectionId: connectionId,
        hostId: hostId,
        client: result.client!,
        config: config,
        dependentClients: result.dependentClients,
        terminalThemeLightId: useHostThemeOverrides
            ? host.terminalThemeLightId
            : null,
        terminalThemeDarkId: useHostThemeOverrides
            ? host.terminalThemeDarkId
            : null,
      );

      // Update last connected timestamp
      await hostRepository!.updateLastConnected(hostId);
      DiagnosticsLogService.instance.info(
        'ssh.connect',
        'connect_to_host_success',
        fields: {
          'hostId': hostId,
          'connectionId': connectionId,
          'usesJumpHost': config.jumpHost != null,
          'usesPassword': config.password != null,
          'identityCount': config.identityKeys?.length ?? 0,
        },
      );
      return SshConnectionResult(
        success: true,
        client: result.client,
        connectionId: connectionId,
        dependentClients: result.dependentClients,
      );
    }

    DiagnosticsLogService.instance.warning(
      'ssh.connect',
      'connect_to_host_failed',
      fields: {
        'hostId': hostId,
        'errorType': _diagnosticSshResultErrorKind(result.error),
      },
    );
    return result;
  }

  /// Connect with a configuration.
  Future<SshConnectionResult> connect(
    SshConnectionConfig config, {
    ConnectionProgressCallback? onProgress,
    bool isJumpHost = false,
  }) async {
    SSHClient? client;
    final dependentClients = <SSHClient>[];
    SSHClient? jumpClient;
    void report(SshConnectionState state, String message) {
      DiagnosticsLogService.instance.info(
        'ssh.connect',
        'progress',
        fields: {'state': state, 'isJumpHost': isJumpHost},
      );
      onProgress?.call(
        ConnectionProgressUpdate(state: state, message: message),
      );
    }

    try {
      DiagnosticsLogService.instance.info(
        'ssh.connect',
        'connect_start',
        fields: {
          'isJumpHost': isJumpHost,
          'hasJumpHost': config.jumpHost != null,
          'usesPassword': config.password != null,
          'identityCount': config.identityKeys?.length ?? 0,
          'hasExplicitKey': config.privateKey != null,
          'keepAliveSeconds': config.keepAliveInterval.inSeconds,
          'timeoutSeconds': config.connectionTimeout.inSeconds,
        },
      );
      final verificationService = _createHostKeyVerificationService(config);

      // Handle jump host
      if (config.jumpHost != null) {
        report(SshConnectionState.connecting, 'Connecting to jump host…');
        final jumpResult = await connect(
          config.jumpHost!,
          onProgress: onProgress,
          isJumpHost: true,
        );
        if (!jumpResult.success || jumpResult.client == null) {
          return SshConnectionResult(
            success: false,
            error: 'Failed to connect to jump host: ${jumpResult.error}',
          );
        }
        dependentClients
          ..add(jumpResult.client!)
          ..addAll(jumpResult.dependentClients);
        jumpClient = jumpResult.client;
      }

      Future<SSHSocket> openEndpointSocket() async {
        if (jumpClient != null) {
          // Create forwarded connection through jump host.
          // SSHForwardChannel implements SSHSocket.
          report(
            SshConnectionState.connecting,
            'Opening tunnel to destination…',
          );
          return jumpClient.forwardLocal(config.hostname, config.port);
        }

        report(
          SshConnectionState.connecting,
          isJumpHost
              ? 'Opening jump host connection…'
              : 'Opening network connection…',
        );
        return _socketConnector(
          config.hostname,
          config.port,
          timeout: config.connectionTimeout,
        );
      }

      final knownHosts = knownHostsRepository!;
      final trustedHost = await knownHosts.getByHost(
        config.hostname,
        config.port,
      );

      if (trustedHost == null) {
        report(
          SshConnectionState.connecting,
          isJumpHost ? 'Verifying jump host key…' : 'Verifying host key…',
        );
        final presentedHostKey = await _probeHostKey(
          await openEndpointSocket(),
          config: config,
        );
        final pendingHostTrustUpdate = await verificationService.verify(
          presentedHostKey,
        );
        await pendingHostTrustUpdate.persistTrustDecision(knownHosts);

        final socket = await openEndpointSocket();

        report(
          SshConnectionState.authenticating,
          isJumpHost ? 'Authenticating with jump host…' : 'Authenticating…',
        );
        client = _clientFactory(
          socket,
          username: config.username,
          onVerifyHostKey: (_, fingerprint) {
            if (!_probedHostKeyMatchesCallback(presentedHostKey, fingerprint)) {
              throw HostKeyVerificationException(
                'The host key for ${config.hostname}:${config.port} changed '
                'between verification and authentication.',
              );
            }
            return true;
          },
          onPasswordRequest: config.password != null
              ? () => config.password!
              : null,
          identities: _parseIdentities(config),
          keepAliveInterval: config.keepAliveInterval,
        );

        // Bound authentication waits so the progress dialog can surface a
        // recoverable error instead of hanging indefinitely.
        await client.authenticated.timeout(
          config.connectionTimeout,
          onTimeout: () => throw TimeoutException(
            isJumpHost
                ? 'Jump host authentication timed out'
                : 'Authentication timed out',
          ),
        );
        report(
          SshConnectionState.connected,
          isJumpHost ? 'Jump host connected.' : 'SSH connection established.',
        );
        await pendingHostTrustUpdate.commitAfterAuthentication(knownHosts);

        DiagnosticsLogService.instance.info(
          'ssh.connect',
          'connect_success',
          fields: {'isJumpHost': isJumpHost, 'trustedHostKnown': false},
        );
        return SshConnectionResult(
          success: true,
          client: client,
          dependentClients: dependentClients,
        );
      }

      final preparedSocket = _prepareHostKeyCapture(await openEndpointSocket());
      String? callbackKeyType;
      String? rejectedCallbackFingerprint;
      var rejectedTrustedHostKey = false;

      report(
        SshConnectionState.authenticating,
        isJumpHost ? 'Authenticating with jump host…' : 'Authenticating…',
      );
      client = _clientFactory(
        preparedSocket.socket,
        username: config.username,
        onVerifyHostKey: (type, fingerprint) {
          callbackKeyType = type;
          final trusted = _trustedHostMatchesCallback(trustedHost, fingerprint);
          rejectedTrustedHostKey = !trusted;
          if (!trusted) {
            rejectedCallbackFingerprint = _formatLegacyFingerprintBytes(
              fingerprint,
            );
          }
          return trusted;
        },
        onPasswordRequest: config.password != null
            ? () => config.password!
            : null,
        identities: _parseIdentities(config),
        keepAliveInterval: config.keepAliveInterval,
      );

      try {
        await client.authenticated.timeout(
          config.connectionTimeout,
          onTimeout: () => throw TimeoutException(
            isJumpHost
                ? 'Jump host authentication timed out'
                : 'Authentication timed out',
          ),
        );
      } on SSHHostkeyError {
        if (!rejectedTrustedHostKey) {
          rethrow;
        }

        client.close();
        client = null;

        report(
          SshConnectionState.connecting,
          isJumpHost ? 'Verifying jump host key…' : 'Verifying host key…',
        );
        final changedHostKey = await _readPresentedHostKey(
          preparedSocket.hostKeySource,
          config: config,
          keyType: callbackKeyType,
        );
        _confirmCapturedHostKeyMatchesCallback(
          changedHostKey,
          rejectedCallbackFingerprint,
          config: config,
        );
        final pendingHostTrustUpdate = await verificationService.verify(
          changedHostKey,
        );

        final retrySocket = await openEndpointSocket();
        report(
          SshConnectionState.authenticating,
          isJumpHost ? 'Authenticating with jump host…' : 'Authenticating…',
        );
        client = _clientFactory(
          retrySocket,
          username: config.username,
          onVerifyHostKey: (_, fingerprint) {
            if (!_probedHostKeyMatchesCallback(changedHostKey, fingerprint)) {
              throw HostKeyVerificationException(
                'The host key for ${config.hostname}:${config.port} changed '
                'between verification and authentication.',
              );
            }
            return true;
          },
          onPasswordRequest: config.password != null
              ? () => config.password!
              : null,
          identities: _parseIdentities(config),
          keepAliveInterval: config.keepAliveInterval,
        );

        await client.authenticated.timeout(
          config.connectionTimeout,
          onTimeout: () => throw TimeoutException(
            isJumpHost
                ? 'Jump host authentication timed out'
                : 'Authentication timed out',
          ),
        );
        report(
          SshConnectionState.connected,
          isJumpHost ? 'Jump host connected.' : 'SSH connection established.',
        );
        await pendingHostTrustUpdate.commitAfterAuthentication(knownHosts);

        DiagnosticsLogService.instance.info(
          'ssh.connect',
          'connect_success',
          fields: {'isJumpHost': isJumpHost, 'trustedHostKnown': true},
        );
        return SshConnectionResult(
          success: true,
          client: client,
          dependentClients: dependentClients,
        );
      }

      report(
        SshConnectionState.connected,
        isJumpHost ? 'Jump host connected.' : 'SSH connection established.',
      );
      await knownHosts.markTrustedHostSeen(
        hostname: trustedHost.hostname,
        port: trustedHost.port,
        keyType: trustedHost.keyType,
        fingerprint: trustedHost.fingerprint,
        encodedHostKey: trustedHost.hostKey,
      );

      DiagnosticsLogService.instance.info(
        'ssh.connect',
        'connect_success',
        fields: {'isJumpHost': isJumpHost, 'trustedHostKnown': true},
      );
      return SshConnectionResult(
        success: true,
        client: client,
        dependentClients: dependentClients,
      );
    } on HostKeyVerificationException catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_failed',
        fields: {'isJumpHost': isJumpHost, 'errorType': e.runtimeType},
      );
      client?.close();
      _closeClients(dependentClients);
      return SshConnectionResult(success: false, error: e.message);
    } on SSHHostkeyError catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_failed',
        fields: {'isJumpHost': isJumpHost, 'errorType': e.runtimeType},
      );
      client?.close();
      _closeClients(dependentClients);
      return SshConnectionResult(
        success: false,
        error: 'Host key verification failed: ${e.message}',
      );
    } on SSHAuthFailError catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_failed',
        fields: {'isJumpHost': isJumpHost, 'errorType': e.runtimeType},
      );
      client?.close();
      _closeClients(dependentClients);
      return SshConnectionResult(
        success: false,
        error: 'Authentication failed: ${e.message}',
      );
    } on SocketException catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_failed',
        fields: {'isJumpHost': isJumpHost, 'errorType': e.runtimeType},
      );
      client?.close();
      _closeClients(dependentClients);
      return SshConnectionResult(
        success: false,
        error: 'Connection failed: ${e.message}',
      );
    } on TimeoutException catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_failed',
        fields: {'isJumpHost': isJumpHost, 'errorType': e.runtimeType},
      );
      client?.close();
      _closeClients(dependentClients);
      return SshConnectionResult(
        success: false,
        error: e.message ?? 'Connection timed out',
      );
    } on Exception catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_failed',
        fields: {'isJumpHost': isJumpHost, 'errorType': e.runtimeType},
      );
      client?.close();
      _closeClients(dependentClients);
      return const SshConnectionResult(
        success: false,
        error: 'Connection failed. Check the host settings and try again.',
      );
    }
  }

  HostKeyVerificationService _createHostKeyVerificationService(
    SshConnectionConfig config,
  ) {
    final repository = knownHostsRepository;
    if (repository == null) {
      throw HostKeyVerificationException(
        'SSH host key verification is unavailable for '
        '${config.hostname}:${config.port}.',
      );
    }

    return HostKeyVerificationService(
      knownHostsRepository: repository,
      promptHandler: hostKeyPromptHandler,
    );
  }

  Future<VerifiedHostKey> _probeHostKey(
    SSHSocket socket, {
    required SshConnectionConfig config,
  }) async {
    final verificationSocket = _prepareHostKeyCapture(socket);
    SSHClient? probeClient;
    Future<void>? probeAuthentication;
    String? callbackKeyType;
    String? callbackFingerprint;

    if (socket is! HostKeySource) {
      probeClient = _clientFactory(
        verificationSocket.socket,
        username: config.username,
        onVerifyHostKey: (type, fingerprint) {
          callbackKeyType = type;
          callbackFingerprint = _formatLegacyFingerprintBytes(fingerprint);
          return true;
        },
      );
      probeAuthentication = _drainHostKeyProbeAuthentication(probeClient);
    }

    try {
      final presentedHostKey = await _readPresentedHostKey(
        verificationSocket.hostKeySource,
        config: config,
        keyType: callbackKeyType,
      );
      _confirmCapturedHostKeyMatchesCallback(
        presentedHostKey,
        callbackFingerprint,
        config: config,
      );
      return presentedHostKey;
    } finally {
      if (probeAuthentication != null) {
        await probeAuthentication;
      }
      probeClient?.close();
      await verificationSocket.socket.close();
    }
  }

  Future<void> _drainHostKeyProbeAuthentication(SSHClient probeClient) async {
    final authentication = probeClient.authenticated.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        DiagnosticsLogService.instance.info(
          'ssh.host_key',
          'probe_authentication_ended',
          fields: {'errorType': error.runtimeType},
        );
      },
    );
    await authentication.timeout(_hostKeyProbeSettleTimeout, onTimeout: () {});
  }

  _PreparedHostKeySocket _prepareHostKeyCapture(SSHSocket socket) {
    final verificationSocket = socket is HostKeySource
        ? socket
        : _HostKeyCapturingSocket(socket);
    return _PreparedHostKeySocket(
      socket: verificationSocket,
      hostKeySource: verificationSocket as HostKeySource,
    );
  }

  Future<VerifiedHostKey> _readPresentedHostKey(
    HostKeySource hostKeySource, {
    required SshConnectionConfig config,
    required String? keyType,
  }) async {
    final hostKeyBytes = await hostKeySource.hostKeyBytes.timeout(
      config.connectionTimeout,
      onTimeout: () => throw HostKeyVerificationException(
        'Timed out while reading the host key for '
        '${config.hostname}:${config.port}.',
      ),
    );
    return VerifiedHostKey(
      hostname: config.hostname,
      port: config.port,
      keyType:
          keyType ?? canonicalizeSshHostKeyType('', hostKeyBytes: hostKeyBytes),
      hostKeyBytes: hostKeyBytes,
    );
  }

  void _confirmCapturedHostKeyMatchesCallback(
    VerifiedHostKey presentedHostKey,
    String? callbackFingerprint, {
    required SshConnectionConfig config,
  }) {
    if (callbackFingerprint != null &&
        callbackFingerprint != presentedHostKey.md5Fingerprint) {
      throw HostKeyVerificationException(
        'Failed to confirm the presented host key for '
        '${config.hostname}:${config.port}.',
      );
    }
  }

  bool _trustedHostMatchesCallback(
    KnownHost trustedHost,
    Uint8List fingerprint,
  ) => sshHostTrustMatches(
    firstFingerprint: trustedHost.fingerprint,
    firstEncodedHostKey: trustedHost.hostKey,
    secondFingerprint: _formatLegacyFingerprintBytes(fingerprint),
    secondEncodedHostKey: '',
  );

  bool _probedHostKeyMatchesCallback(
    VerifiedHostKey presentedHostKey,
    Uint8List fingerprint,
  ) =>
      presentedHostKey.md5Fingerprint ==
      _formatLegacyFingerprintBytes(fingerprint);

  String _formatLegacyFingerprintBytes(Uint8List fingerprint) => fingerprint
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join(':');

  /// Disconnect a session by connection ID.
  Future<void> disconnect(int connectionId) async {
    DiagnosticsLogService.instance.info(
      'ssh.session',
      'disconnect',
      fields: {'connectionId': connectionId},
    );
    final session = _sessions.remove(connectionId);
    await session?.close();
  }

  /// Disconnect all sessions.
  Future<void> disconnectAll() async {
    DiagnosticsLogService.instance.info(
      'ssh.session',
      'disconnect_all',
      fields: {'connectionCount': _sessions.length},
    );
    for (final session in _sessions.values) {
      await session.close();
    }
    _sessions.clear();
  }

  /// Get a session by connection ID.
  SshSession? getSession(int connectionId) => _sessions[connectionId];

  /// Get all sessions for a host.
  List<SshSession> getSessionsForHost(int hostId) => _sessions.values
      .where((session) => session.hostId == hostId)
      .toList(growable: false);

  /// Check if a connection ID is active.
  bool isConnected(int connectionId) => _sessions.containsKey(connectionId);

  List<SSHKeyPair>? _parseIdentities(SshConnectionConfig config) {
    final identityKeyPairs = <SSHKeyPair>[];
    if (config.identityKeys != null) {
      for (final key in config.identityKeys!) {
        final parsed = _parsePrivateKey(key.privateKey, key.passphrase);
        if (parsed != null) {
          identityKeyPairs.addAll(parsed);
        }
      }
    }
    if (identityKeyPairs.isNotEmpty) {
      return identityKeyPairs;
    }
    if (config.privateKey != null) {
      return _parsePrivateKey(config.privateKey!, config.passphrase);
    }
    return null;
  }

  List<SSHKeyPair>? _parsePrivateKey(String privateKey, String? passphrase) {
    try {
      if (passphrase != null && passphrase.isNotEmpty) {
        return SSHKeyPair.fromPem(privateKey, passphrase);
      }
      return SSHKeyPair.fromPem(privateKey);
    } on FormatException {
      return null;
    }
  }

  static void _closeClients(List<SSHClient> clients) {
    for (final client in clients) {
      client.close();
    }
  }

  static SSHClient _defaultClientFactory(
    SSHSocket socket, {
    required String username,
    SSHHostkeyVerifyHandler? onVerifyHostKey,
    SSHPasswordRequestHandler? onPasswordRequest,
    List<SSHKeyPair>? identities,
    Duration? keepAliveInterval,
  }) => SSHClient(
    socket,
    username: username,
    onVerifyHostKey: onVerifyHostKey,
    onPasswordRequest: onPasswordRequest,
    identities: identities,
    keepAliveInterval: keepAliveInterval,
  );

  /// Connects a TCP socket with OS-level keepalive enabled so the connection
  /// survives brief periods in the background without the OS tearing it down.
  static Future<SSHSocket> _connectWithKeepAlive(
    String host,
    int port, {
    Duration? timeout,
  }) async {
    // ignore: close_sinks — socket is closed via _KeepAliveSSHSocket.close()
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    try {
      _enableTcpKeepAlive(socket);
    } on Exception {
      // Fallback: not all platforms support raw socket options.
    }
    return _KeepAliveSSHSocket(socket);
  }

  /// Enables aggressive TCP keepalive so the OS sends probes every 15s
  /// instead of the default ~2 hours, keeping the socket alive while
  /// the app is briefly backgrounded.
  static void _enableTcpKeepAlive(Socket socket) {
    const ipprotoTcp = 6;
    const keepAliveSeconds = 15;

    if (Platform.isIOS || Platform.isMacOS) {
      socket
        // SO_KEEPALIVE
        ..setRawOption(RawSocketOption.fromBool(0xFFFF, 0x0008, true))
        // TCP_KEEPALIVE (idle time before first probe)
        ..setRawOption(
          RawSocketOption.fromInt(ipprotoTcp, 0x10, keepAliveSeconds),
        )
        // TCP_KEEPINTVL (interval between probes)
        ..setRawOption(
          RawSocketOption.fromInt(ipprotoTcp, 0x101, keepAliveSeconds),
        )
        // TCP_KEEPCNT (number of failed probes before giving up)
        ..setRawOption(RawSocketOption.fromInt(ipprotoTcp, 0x102, 3));
    } else if (Platform.isAndroid || Platform.isLinux) {
      socket
        // SO_KEEPALIVE
        ..setRawOption(RawSocketOption.fromBool(1, 9, true))
        // TCP_KEEPIDLE
        ..setRawOption(RawSocketOption.fromInt(ipprotoTcp, 4, keepAliveSeconds))
        // TCP_KEEPINTVL
        ..setRawOption(RawSocketOption.fromInt(ipprotoTcp, 5, keepAliveSeconds))
        // TCP_KEEPCNT
        ..setRawOption(RawSocketOption.fromInt(ipprotoTcp, 6, 3));
    }
  }
}

/// SSHSocket wrapper that enables TCP keepalive on the underlying socket.
class _KeepAliveSSHSocket implements SSHSocket {
  _KeepAliveSSHSocket(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> close() async => _socket.close();

  @override
  Future<void> get done => _socket.done;

  @override
  void destroy() => _socket.destroy();
}

class _FiniteChunkSshSocket implements SSHSocket {
  _FiniteChunkSshSocket(Iterable<Uint8List> chunks)
    : _stream = Stream<Uint8List>.fromIterable(chunks);

  final Stream<Uint8List> _stream;
  final _sinkController = StreamController<List<int>>();

  @override
  Stream<Uint8List> get stream => _stream;

  @override
  StreamSink<List<int>> get sink => _sinkController.sink;

  @override
  Future<void> close() => _sinkController.close();

  @override
  Future<void> get done async {}

  @override
  void destroy() {}
}

class _PreparedHostKeySocket {
  const _PreparedHostKeySocket({
    required this.socket,
    required this.hostKeySource,
  });

  final SSHSocket socket;
  final HostKeySource hostKeySource;
}

Map<String, Object?> _diagnosticSshExecErrorFields(Object error) => {
  'errorType': error.runtimeType,
  if (error is SSHChannelOpenError) ...{
    'channelOpenCode': error.code,
    'reason': _diagnosticSshChannelOpenReason(error.description),
  },
};

String _diagnosticSshChannelOpenReason(String description) {
  final normalized = description.toLowerCase();
  if (normalized.contains('administratively prohibited')) {
    return 'administratively_prohibited';
  }
  if (normalized.contains('resource shortage')) {
    return 'resource_shortage';
  }
  if (normalized.contains('connect failed')) {
    return 'connect_failed';
  }
  if (normalized.contains('unknown channel type')) {
    return 'unknown_channel_type';
  }
  if (normalized.contains('open failed')) {
    return 'open_failed';
  }
  return 'channel_open_failed';
}

String _diagnosticSshResultErrorKind(String? error) {
  if (error == null || error.isEmpty) {
    return 'unknown';
  }
  if (error.startsWith('Authentication failed')) {
    return 'authentication_failed';
  }
  if (error.startsWith('Host key verification failed')) {
    return 'host_key_verification_failed';
  }
  if (error.startsWith('Connection failed')) {
    return 'connection_failed';
  }
  if (error.contains('timed out')) {
    return 'timeout';
  }
  return 'connection_error';
}

String _diagnosticSshCommandKind(String command) {
  final trimmed = command.trimLeft();
  if (trimmed.startsWith('tmux ') ||
      trimmed.startsWith('tmux -u ') ||
      trimmed.contains(' tmux ') ||
      trimmed.contains('/tmux ')) {
    return 'tmux';
  }
  if (trimmed.contains('command -v')) {
    return 'command_detection';
  }
  if (trimmed.contains('__flutty_tmux_exec_done__')) {
    return 'tmux_marked_exec';
  }
  return 'ssh_exec';
}

class _HostKeyCapturingSocket implements SSHSocket, HostKeySource {
  _HostKeyCapturingSocket(this._delegate)
    : _hostKeyParser = _SshHostKeyParser() {
    _stream = _delegate.stream.map((chunk) {
      _hostKeyParser.addChunk(chunk);
      return chunk;
    });
  }

  final SSHSocket _delegate;
  final _SshHostKeyParser _hostKeyParser;
  late final Stream<Uint8List> _stream;

  @override
  Future<Uint8List> get hostKeyBytes => _hostKeyParser.hostKeyBytes;

  @override
  Stream<Uint8List> get stream => _stream;

  @override
  StreamSink<List<int>> get sink => _delegate.sink;

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<void> get done => _delegate.done;

  @override
  void destroy() => _delegate.destroy();
}

class _SshHostKeyParser {
  static const _maxBufferedBytes = 256 * 1024;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  final Completer<Uint8List> _hostKeyBytes = Completer<Uint8List>();
  final BytesBuilder _versionBuffer = BytesBuilder(copy: false);
  bool _versionSeen = false;

  Future<Uint8List> get hostKeyBytes => _hostKeyBytes.future;

  void addChunk(Uint8List chunk) {
    if (_hostKeyBytes.isCompleted) {
      return;
    }

    if (!_versionSeen) {
      _consumeVersionBytes(chunk);
      return;
    }

    _buffer.add(chunk);
    _failIfBufferLimitExceeded(
      _buffer.length,
      context:
          'SSH handshake packet buffer exceeded '
          '$_maxBufferedBytes bytes before the host key was parsed.',
    );
    _parsePackets();
  }

  void _consumeVersionBytes(Uint8List chunk) {
    _versionBuffer.add(chunk);
    _failIfBufferLimitExceeded(
      _versionBuffer.length,
      context:
          'SSH identification exchange exceeded $_maxBufferedBytes bytes '
          'before a protocol version line was received.',
    );
    final bytes = _versionBuffer.takeBytes();
    var searchStart = 0;
    while (true) {
      final newlineIndex = bytes.indexOf(0x0A, searchStart);
      if (newlineIndex == -1) {
        _versionBuffer.add(bytes.sublist(searchStart));
        return;
      }

      final lineBytes = bytes.sublist(searchStart, newlineIndex + 1);
      final line = utf8.decode(lineBytes, allowMalformed: true).trim();
      searchStart = newlineIndex + 1;
      if (!line.startsWith('SSH-')) {
        continue;
      }

      _versionSeen = true;
      if (searchStart < bytes.length) {
        _buffer.add(bytes.sublist(searchStart));
        _parsePackets();
      }
      return;
    }
  }

  void _parsePackets() {
    final data = _buffer.takeBytes();
    var offset = 0;
    while (!_hostKeyBytes.isCompleted && data.length - offset >= 5) {
      final packetLength = _readUint32(data, offset);
      if (packetLength + 4 > _maxBufferedBytes) {
        _fail(
          'SSH handshake packet length $packetLength exceeds the '
          '$_maxBufferedBytes-byte host-key capture limit.',
        );
        return;
      }
      if (packetLength < 1 || data.length - offset < packetLength + 4) {
        break;
      }

      final paddingLength = data[offset + 4];
      final payloadLength = packetLength - paddingLength - 1;
      if (payloadLength > 0) {
        final payloadStart = offset + 5;
        final payloadEnd = payloadStart + payloadLength;
        final payload = Uint8List.sublistView(data, payloadStart, payloadEnd);
        _tryCaptureHostKey(payload);
      }

      offset += packetLength + 4;
    }

    if (offset < data.length) {
      _buffer.add(data.sublist(offset));
    }
  }

  void _failIfBufferLimitExceeded(int length, {required String context}) {
    if (length > _maxBufferedBytes) {
      _fail(context);
    }
  }

  void _fail(String message) {
    if (_hostKeyBytes.isCompleted) {
      return;
    }
    _hostKeyBytes.completeError(HostKeyVerificationException(message));
  }

  void _tryCaptureHostKey(Uint8List payload) {
    if (payload.isEmpty) {
      return;
    }

    final messageId = payload[0];
    if (messageId != 31 && messageId != 33) {
      return;
    }

    final hostKey = _readSshString(payload, 1);
    if (hostKey == null || !_looksLikeHostKeyBlob(hostKey)) {
      return;
    }

    _hostKeyBytes.complete(Uint8List.fromList(hostKey));
  }

  bool _looksLikeHostKeyBlob(Uint8List hostKey) {
    final typeBytes = _readSshString(hostKey, 0);
    if (typeBytes == null) {
      return false;
    }

    final type = utf8.decode(typeBytes, allowMalformed: true);
    return type == 'ssh-rsa' ||
        type == 'ssh-ed25519' ||
        type.startsWith('ecdsa-sha2-');
  }

  static int _readUint32(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static Uint8List? _readSshString(Uint8List bytes, int offset) {
    if (bytes.length - offset < 4) {
      return null;
    }

    final length = _readUint32(bytes, offset);
    final start = offset + 4;
    final end = start + length;
    if (length < 0 || end > bytes.length) {
      return null;
    }

    return Uint8List.sublistView(bytes, start, end);
  }
}

/// An active SSH session.
class SshSession {
  /// Creates a new [SshSession].
  SshSession({
    required this.connectionId,
    required this.hostId,
    required this.client,
    required this.config,
    this.dependentClients = const <SSHClient>[],
    this.terminalThemeLightId,
    this.terminalThemeDarkId,
    this.terminalFontSize,
    this.clipboardSharingEnabled = false,
    this.localClipboardReadEnabled = false,
  }) : createdAt = DateTime.now();

  static const _previewRefreshInterval = Duration(milliseconds: 150);
  static const _shellIoDiagnosticsInterval = Duration(seconds: 1);
  static const _previewLineCount = 3;
  static const _previewMaxChars = 220;
  static final _previewSanitizerPattern = RegExp(r'[\x00-\x08\x0B-\x1F\x7F]');
  static final _windowTitleSanitizerPattern = RegExp(r'[\x00-\x1F\x7F]');

  /// The connection ID for this active session.
  final int connectionId;

  /// The host ID this session is connected to.
  final int hostId;

  /// The SSH client.
  final SSHClient client;

  /// The connection configuration.
  final SshConnectionConfig config;

  /// Additional clients that should be closed with the session client.
  final List<SSHClient> dependentClients;

  /// Session-specific light theme override.
  String? terminalThemeLightId;

  /// Session-specific dark theme override.
  String? terminalThemeDarkId;

  /// Session-specific terminal font size override.
  double? terminalFontSize;

  /// Whether OSC 52 clipboard sharing is enabled for this session.
  bool clipboardSharingEnabled;

  /// Whether the remote side may read the local clipboard.
  bool localClipboardReadEnabled;

  /// When the session was created.
  final DateTime createdAt;

  final ClipboardSharingService _clipboardSharingService =
      const ClipboardSharingService();

  SSHSession? _shell;
  StreamController<String>? _shellStdoutController;
  StreamController<String>? _shellStderrController;
  StreamController<void>? _shellDoneController;
  StreamSubscription<String>? _shellStdoutSubscription;
  StreamSubscription<String>? _shellStderrSubscription;
  StreamSubscription<void>? _shellDoneSubscription;
  Timer? _previewRefreshTimer;
  Timer? _shellIoDiagnosticsTimer;
  int _shellStdoutChunkCount = 0;
  int _shellStdoutCharCount = 0;
  int _shellStderrChunkCount = 0;
  int _shellStderrCharCount = 0;
  int _shellStdinWriteCount = 0;
  int _shellStdinCharCount = 0;
  TerminalWindowMetrics? _terminalWindowMetrics;
  String _terminalWindowQueryPendingInput = '';
  String _terminalTmuxPassthroughPendingInput = '';
  String _terminalControlModeUpdatePendingInput = '';
  bool _terminalColorSchemeUpdatesMode = false;

  /// Persistent terminal that survives screen rebuilds.
  Terminal? _terminal;

  /// The active terminal theme used to answer remote OSC color queries.
  TerminalThemeData? terminalTheme;

  /// Whether the foreground app requested xterm color-scheme update reports.
  bool get terminalColorSchemeUpdatesMode => _terminalColorSchemeUpdatesMode;

  /// Tracks OSC 8 hyperlinks rendered in the persistent terminal.
  final terminalHyperlinkTracker = TerminalHyperlinkTracker();

  final _previewListeners = <VoidCallback>{};
  final _metadataListeners = <VoidCallback>{};
  String? _terminalPreview;
  String? _windowTitle;
  String? _iconName;
  Uri? _workingDirectory;
  TerminalShellStatus? _shellStatus;
  int? _lastExitCode;

  /// The persistent terminal for this session. Created on first shell open.
  Terminal? get terminal => _terminal;

  /// A plain-text preview of the latest terminal content.
  String? get terminalPreview => _terminalPreview;

  /// The latest terminal window title emitted by the remote session.
  String? get windowTitle => _windowTitle;

  /// The latest terminal icon name emitted by the remote session.
  String? get iconName => _iconName;

  /// The latest working-directory URI emitted through OSC 7.
  Uri? get workingDirectory => _workingDirectory;

  /// The latest shell integration status emitted through OSC 133.
  TerminalShellStatus? get shellStatus => _shellStatus;

  /// The latest command exit code emitted through shell integration.
  int? get lastExitCode => _lastExitCode;

  /// Records visible terminal dimensions used to answer size report queries.
  void updateTerminalWindowMetrics({
    required int columns,
    required int rows,
    required int pixelWidth,
    required int pixelHeight,
  }) {
    _terminalWindowMetrics = (
      columns: columns,
      rows: rows,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
  }

  /// Adds a listener for terminal preview and preview-adjacent metadata changes.
  void addPreviewListener(VoidCallback listener) {
    _previewListeners.add(listener);
  }

  /// Removes a preview listener previously added with [addPreviewListener].
  void removePreviewListener(VoidCallback listener) {
    _previewListeners.remove(listener);
  }

  /// Adds a listener for metadata changes used by the live terminal screen.
  void addMetadataListener(VoidCallback listener) {
    _metadataListeners.add(listener);
  }

  /// Removes a metadata listener previously added with [addMetadataListener].
  void removeMetadataListener(VoidCallback listener) {
    _metadataListeners.remove(listener);
  }

  /// Persist a per-session terminal theme override.
  ///
  /// Returns `true` when the stored theme ID changed.
  bool setTerminalThemeId(String themeId, {required bool isDark}) {
    if (isDark) {
      if (terminalThemeDarkId == themeId) {
        return false;
      }
      terminalThemeDarkId = themeId;
      return true;
    }
    if (terminalThemeLightId == themeId) {
      return false;
    }
    terminalThemeLightId = themeId;
    return true;
  }

  /// Ensure a [Terminal] exists and is wired to the shell streams.
  Terminal getOrCreateTerminal({int maxLines = 10000}) {
    _terminal ??= Terminal(maxLines: maxLines);
    _terminal!
      ..onTitleChange = _handleWindowTitleChange
      ..onIconChange = _handleIconNameChange;
    terminalHyperlinkTracker.attach(_terminal!);
    _terminal!.onPrivateOSC = _handlePrivateOsc;
    _refreshTerminalPreview();
    return _terminal!;
  }

  /// Active port forward tunnels.
  final Map<int, _ActiveTunnel> _activeTunnels = {};

  /// Get active tunnel info for display.
  List<ActiveTunnelInfo> get activeTunnels => _activeTunnels.entries
      .map(
        (e) => ActiveTunnelInfo(
          portForwardId: e.key,
          localPort: e.value.localPort,
          remoteHost: e.value.remoteHost,
          remotePort: e.value.remotePort,
          isLocal: e.value.isLocal,
        ),
      )
      .toList();

  /// Get or create a shell session.
  Future<SSHSession> getShell({
    SSHPtyConfig? pty,
    bool forceNew = false,
  }) async {
    if (forceNew) {
      await closeShell();
    }
    if (_shell == null) {
      DiagnosticsLogService.instance.info(
        'ssh.shell',
        'open_start',
        fields: {
          'connectionId': connectionId,
          'hostId': hostId,
          'requestedPty': pty != null,
        },
      );
      try {
        _shell = await client.shell(pty: pty ?? const SSHPtyConfig());
        DiagnosticsLogService.instance.info(
          'ssh.shell',
          'open_success',
          fields: {'connectionId': connectionId},
        );
      } on Object catch (error) {
        DiagnosticsLogService.instance.error(
          'ssh.shell',
          'open_failed',
          fields: {
            'connectionId': connectionId,
            'errorType': error.runtimeType,
          },
        );
        rethrow;
      }
    } else {
      DiagnosticsLogService.instance.debug(
        'ssh.shell',
        'reuse_existing',
        fields: {'connectionId': connectionId},
      );
    }
    _ensureShellStreamPipes();
    return _shell!;
  }

  /// Shell stdout as a broadcast stream for screen re-attachment.
  Stream<String> get shellStdoutStream =>
      _shellStdoutController?.stream ?? const Stream.empty();

  /// Shell stderr as a broadcast stream for screen re-attachment.
  Stream<String> get shellStderrStream =>
      _shellStderrController?.stream ?? const Stream.empty();

  /// Shell done event stream for screen re-attachment.
  Stream<void> get shellDoneStream =>
      _shellDoneController?.stream ?? const Stream.empty();

  /// Close only the interactive shell channel while keeping the SSH client.
  Future<void> closeShell({bool waitForStreams = true}) async {
    _flushShellIoDiagnostics();
    _shellIoDiagnosticsTimer?.cancel();
    _shellIoDiagnosticsTimer = null;
    DiagnosticsLogService.instance.info(
      'ssh.shell',
      'close_start',
      fields: {'connectionId': connectionId, 'hadShell': _shell != null},
    );
    _previewRefreshTimer?.cancel();
    _previewRefreshTimer = null;
    if (waitForStreams) {
      await _shellStdoutSubscription?.cancel();
      await _shellStderrSubscription?.cancel();
      await _shellDoneSubscription?.cancel();
    } else {
      unawaited(_shellStdoutSubscription?.cancel());
      unawaited(_shellStderrSubscription?.cancel());
      unawaited(_shellDoneSubscription?.cancel());
    }
    _shellStdoutSubscription = null;
    _shellStderrSubscription = null;
    _shellDoneSubscription = null;

    if (waitForStreams) {
      await _shellStdoutController?.close();
      await _shellStderrController?.close();
      await _shellDoneController?.close();
    } else {
      unawaited(_shellStdoutController?.close());
      unawaited(_shellStderrController?.close());
      unawaited(_shellDoneController?.close());
    }
    _shellStdoutController = null;
    _shellStderrController = null;
    _shellDoneController = null;

    _shell?.close();
    _shell = null;
    terminalHyperlinkTracker.reset(keepTerminalReference: false);
    _iconName = null;
    _workingDirectory = null;
    _shellStatus = null;
    _lastExitCode = null;
    _terminalWindowMetrics = null;
    _terminalWindowQueryPendingInput = '';
    _terminalTmuxPassthroughPendingInput = '';
    _terminalControlModeUpdatePendingInput = '';
    _terminalColorSchemeUpdatesMode = false;
    _terminal = null;
    _terminalPreview = null;
    _windowTitle = null;
    DiagnosticsLogService.instance.info(
      'ssh.shell',
      'close_complete',
      fields: {'connectionId': connectionId},
    );
  }

  void _ensureShellStreamPipes() {
    if (_shell == null || _shellStdoutController != null) {
      return;
    }

    final shell = _shell!;
    final terminal = getOrCreateTerminal();
    _shellStdoutController = StreamController<String>.broadcast();
    _shellStderrController = StreamController<String>.broadcast();
    _shellDoneController = StreamController<void>.broadcast();

    _shellStdoutSubscription = shell.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .listen(
          (data) {
            _recordShellIo(stdoutChars: data.length);
            final terminalData = _unwrapTerminalTmuxPassthrough(data);
            if (terminalData.isNotEmpty) {
              terminal.write(terminalData);
              _respondToTerminalWindowControlQueries(terminalData, terminal);
            }
            _scheduleTerminalPreviewRefresh();
            final stdoutController = _shellStdoutController;
            if (identical(_shell, shell) &&
                stdoutController != null &&
                !stdoutController.isClosed) {
              stdoutController.add(data);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            DiagnosticsLogService.instance.error(
              'ssh.shell',
              'stdout_error',
              fields: {
                'connectionId': connectionId,
                'errorType': error.runtimeType,
              },
            );
            final stdoutController = _shellStdoutController;
            if (identical(_shell, shell) &&
                stdoutController != null &&
                !stdoutController.isClosed) {
              stdoutController.addError(error, stackTrace);
            }
          },
        );
    _shellStderrSubscription = shell.stderr
        .cast<List<int>>()
        .transform(utf8.decoder)
        .listen(
          (data) {
            _recordShellIo(stderrChars: data.length);
            terminal.write(data);
            _scheduleTerminalPreviewRefresh();
            final stderrController = _shellStderrController;
            if (identical(_shell, shell) &&
                stderrController != null &&
                !stderrController.isClosed) {
              stderrController.add(data);
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            DiagnosticsLogService.instance.error(
              'ssh.shell',
              'stderr_error',
              fields: {
                'connectionId': connectionId,
                'errorType': error.runtimeType,
              },
            );
            final stderrController = _shellStderrController;
            if (identical(_shell, shell) &&
                stderrController != null &&
                !stderrController.isClosed) {
              stderrController.addError(error, stackTrace);
            }
          },
        );
    _shellDoneSubscription = shell.done.asStream().listen(
      (_) {
        DiagnosticsLogService.instance.info(
          'ssh.shell',
          'done',
          fields: {'connectionId': connectionId},
        );
        final doneController = _shellDoneController;
        if (identical(_shell, shell) &&
            doneController != null &&
            !doneController.isClosed) {
          doneController.add(null);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        DiagnosticsLogService.instance.error(
          'ssh.shell',
          'done_error',
          fields: {
            'connectionId': connectionId,
            'errorType': error.runtimeType,
          },
        );
        final doneController = _shellDoneController;
        if (identical(_shell, shell) &&
            doneController != null &&
            !doneController.isClosed) {
          doneController.addError(error, stackTrace);
        }
      },
    );

    // Wire terminal keyboard output → shell stdin (persistent).
    terminal.onOutput = (data) {
      final output = normalizeTerminalOutputForRemoteShell(data);
      _recordShellIo(stdinChars: output.length);
      shell.write(utf8.encode(output));
    };
    _refreshTerminalPreview();
  }

  void _recordShellIo({
    int stdoutChars = 0,
    int stderrChars = 0,
    int stdinChars = 0,
  }) {
    if (!DiagnosticsLogService.instance.enabled) {
      return;
    }
    if (stdoutChars > 0) {
      _shellStdoutChunkCount += 1;
      _shellStdoutCharCount += stdoutChars;
    }
    if (stderrChars > 0) {
      _shellStderrChunkCount += 1;
      _shellStderrCharCount += stderrChars;
    }
    if (stdinChars > 0) {
      _shellStdinWriteCount += 1;
      _shellStdinCharCount += stdinChars;
    }
    if (!(_shellIoDiagnosticsTimer?.isActive ?? false)) {
      _shellIoDiagnosticsTimer = Timer(
        _shellIoDiagnosticsInterval,
        _flushShellIoDiagnostics,
      );
    }
  }

  void _flushShellIoDiagnostics() {
    _shellIoDiagnosticsTimer?.cancel();
    _shellIoDiagnosticsTimer = null;
    if (_shellStdoutChunkCount == 0 &&
        _shellStderrChunkCount == 0 &&
        _shellStdinWriteCount == 0) {
      return;
    }
    DiagnosticsLogService.instance.debug(
      'ssh.shell',
      'io_summary',
      fields: {
        'connectionId': connectionId,
        'stdoutChunks': _shellStdoutChunkCount,
        'stdoutChars': _shellStdoutCharCount,
        'stderrChunks': _shellStderrChunkCount,
        'stderrChars': _shellStderrCharCount,
        'stdinWrites': _shellStdinWriteCount,
        'stdinChars': _shellStdinCharCount,
      },
    );
    _shellStdoutChunkCount = 0;
    _shellStdoutCharCount = 0;
    _shellStderrChunkCount = 0;
    _shellStderrCharCount = 0;
    _shellStdinWriteCount = 0;
    _shellStdinCharCount = 0;
  }

  void _respondToTerminalWindowControlQueries(String data, Terminal terminal) {
    final modeUpdateResult = extractTerminalControlModeUpdates(
      input: data,
      pendingInput: _terminalControlModeUpdatePendingInput,
    );
    _terminalControlModeUpdatePendingInput = modeUpdateResult.pendingInput;
    final nextColorSchemeUpdatesMode = modeUpdateResult.colorSchemeUpdatesMode;
    if (nextColorSchemeUpdatesMode != null &&
        nextColorSchemeUpdatesMode != _terminalColorSchemeUpdatesMode) {
      _terminalColorSchemeUpdatesMode = nextColorSchemeUpdatesMode;
    }

    final result = buildTerminalWindowControlQueryResponses(
      input: data,
      pendingInput: _terminalWindowQueryPendingInput,
      metrics: _terminalWindowMetrics,
      modeState: _terminalModeState(terminal),
      theme: terminalTheme,
    );
    _terminalWindowQueryPendingInput = result.pendingInput;

    final response = result.response;
    if (response == null) {
      return;
    }

    _shell?.write(utf8.encode(response));
  }

  String _unwrapTerminalTmuxPassthrough(String data) {
    final result = unwrapTerminalTmuxPassthroughSequences(
      input: data,
      pendingInput: _terminalTmuxPassthroughPendingInput,
    );
    _terminalTmuxPassthroughPendingInput = result.pendingInput;
    return result.output;
  }

  TerminalControlModeState _terminalModeState(Terminal terminal) => (
    reportFocusMode: terminal.reportFocusMode,
    bracketedPasteMode: terminal.bracketedPasteMode,
    colorSchemeUpdatesMode: _terminalColorSchemeUpdatesMode,
    isUsingAltBuffer: terminal.isUsingAltBuffer,
    mouseTrackingMode: terminal.mouseMode == MouseMode.upDownScroll,
    mouseDragTrackingMode: terminal.mouseMode == MouseMode.upDownScrollDrag,
    mouseMoveTrackingMode: terminal.mouseMode == MouseMode.upDownScrollMove,
    sgrMouseReportMode: terminal.mouseReportMode == MouseReportMode.sgr,
  );

  void _scheduleTerminalPreviewRefresh() {
    if (_previewRefreshTimer?.isActive ?? false) {
      return;
    }
    _previewRefreshTimer = Timer(_previewRefreshInterval, () {
      _previewRefreshTimer = null;
      _refreshTerminalPreview();
    });
  }

  void _refreshTerminalPreview() {
    final nextPreview = _terminal == null
        ? null
        : buildTerminalPreview(_terminal!);
    if (nextPreview == _terminalPreview) {
      return;
    }
    _terminalPreview = nextPreview;
    DiagnosticsLogService.instance.debug(
      'ssh.preview',
      'changed',
      fields: {
        'connectionId': connectionId,
        'hasPreview': nextPreview != null,
        'charCount': nextPreview?.length ?? 0,
      },
    );
    _notifyPreviewChanged();
  }

  void _handleWindowTitleChange(String title) {
    final sanitizedTitle = _sanitizeWindowTitle(title);
    if (sanitizedTitle == _windowTitle) {
      return;
    }
    _windowTitle = sanitizedTitle;
    DiagnosticsLogService.instance.debug(
      'ssh.metadata',
      'window_title_changed',
      fields: {
        'connectionId': connectionId,
        'hasTitle': sanitizedTitle != null,
      },
    );
    _notifyMetadataChanged();
  }

  void _handleIconNameChange(String iconName) {
    final sanitizedIconName = _sanitizeWindowTitle(iconName);
    if (sanitizedIconName == _iconName) {
      return;
    }
    _iconName = sanitizedIconName;
    DiagnosticsLogService.instance.debug(
      'ssh.metadata',
      'icon_name_changed',
      fields: {
        'connectionId': connectionId,
        'hasIcon': sanitizedIconName != null,
      },
    );
    _notifyMetadataChanged();
  }

  void _handlePrivateOsc(String code, List<String> args) {
    if (code == '10' || code == '11' || code == '12' || code == '4') {
      DiagnosticsLogService.instance.debug(
        'terminal.osc',
        'theme_query',
        fields: {
          'connectionId': connectionId,
          'code': code,
          'themeId': terminalTheme?.id,
          'hasShell': _shell != null,
        },
      );
    }
    final themeOscResponse = terminalTheme == null
        ? null
        : buildTerminalThemeOscResponse(
            theme: terminalTheme!,
            code: code,
            args: args,
          );
    if (themeOscResponse != null) {
      final shell = _shell;
      if (shell == null) {
        DiagnosticsLogService.instance.warning(
          'terminal.osc',
          'theme_query_dropped_no_shell',
          fields: {
            'connectionId': connectionId,
            'code': code,
            'themeId': terminalTheme?.id,
          },
        );
      } else {
        shell.write(utf8.encode(themeOscResponse));
        DiagnosticsLogService.instance.debug(
          'terminal.osc',
          'theme_query_answered',
          fields: {
            'connectionId': connectionId,
            'code': code,
            'themeId': terminalTheme!.id,
            'responseBytes': themeOscResponse.length,
          },
        );
      }
      return;
    }

    terminalHyperlinkTracker.handlePrivateOsc(code, args);
    if (code == '8') {
      return;
    }

    if (code == '7') {
      final nextWorkingDirectory = parseTerminalWorkingDirectoryUri(args);
      if (nextWorkingDirectory?.toString() == _workingDirectory?.toString()) {
        return;
      }
      _workingDirectory = nextWorkingDirectory;
      DiagnosticsLogService.instance.debug(
        'ssh.metadata',
        'working_directory_changed',
        fields: {
          'connectionId': connectionId,
          'hasWorkingDirectory': nextWorkingDirectory != null,
        },
      );
      _notifyMetadataChanged();
      return;
    }

    if (code == ClipboardSharingService.oscCode) {
      _handleOsc52(args);
      return;
    }

    if (code == '133') {
      final nextShellState = applyTerminalShellIntegrationOsc(
        args,
        previousStatus: _shellStatus,
        previousExitCode: _lastExitCode,
      );
      if (nextShellState.status == _shellStatus &&
          nextShellState.lastExitCode == _lastExitCode) {
        return;
      }
      _shellStatus = nextShellState.status;
      _lastExitCode = nextShellState.lastExitCode;
      DiagnosticsLogService.instance.debug(
        'ssh.metadata',
        'shell_status_changed',
        fields: {
          'connectionId': connectionId,
          'shellStatus': nextShellState.status,
          'lastExitCode': nextShellState.lastExitCode,
        },
      );
      _notifyMetadataChanged();
      return;
    }

    _logUnhandledPrivateOsc(code, args);
  }

  void _logUnhandledPrivateOsc(String code, List<String> args) {
    DiagnosticsLogService.instance.debug(
      'terminal.osc',
      'unhandled',
      fields: {
        'connectionId': connectionId,
        'oscCode': int.tryParse(code) ?? -1,
        'argCount': args.length,
      },
    );
  }

  void _handleOsc52(List<String> args) {
    if (!clipboardSharingEnabled) return;

    unawaited(
      _clipboardSharingService
          .handleOsc52(args, allowLocalClipboardRead: localClipboardReadEnabled)
          .then((response) {
            if (response != null && _shell != null) {
              _shell!.write(utf8.encode(response));
            }
          })
          .catchError((Object error, StackTrace stackTrace) {
            DiagnosticsLogService.instance.warning(
              'ssh.clipboard',
              'osc52_failed',
              fields: {'errorType': error.runtimeType},
            );
            if (kDebugMode) {
              debugPrint('Error handling OSC 52 sequence: $error');
              debugPrint('$stackTrace');
            }
          }),
    );
  }

  /// Builds a compact plain-text preview from the terminal scrollback.
  static String? buildTerminalPreview(
    Terminal terminal, {
    int maxLines = _previewLineCount,
    int maxChars = _previewMaxChars,
  }) {
    final effectiveMaxLines = maxLines < 1 ? 1 : maxLines;
    final effectiveMaxChars = maxChars < 1 ? 1 : maxChars;
    final previewLines = <String>[];
    final currentSegments = <String>[];

    for (
      var index = terminal.lines.length - 1;
      index >= 0 && previewLines.length < effectiveMaxLines;
      index--
    ) {
      final rawLine = terminal.lines[index].getText();
      final cleanedLine = _sanitizePreviewFragment(rawLine);

      if (cleanedLine.isEmpty) {
        if (currentSegments.isNotEmpty) {
          previewLines.insert(0, currentSegments.reversed.join());
          currentSegments.clear();
        }
        continue;
      }

      currentSegments.add(cleanedLine);
      if (!terminal.lines[index].isWrapped) {
        previewLines.insert(0, currentSegments.reversed.join());
        currentSegments.clear();
      }
    }

    if (currentSegments.isNotEmpty && previewLines.length < effectiveMaxLines) {
      previewLines.insert(0, currentSegments.reversed.join());
    }

    if (previewLines.isEmpty) {
      return null;
    }

    var preview = previewLines.join('\n');
    if (preview.length > effectiveMaxChars) {
      preview = '…${preview.substring(preview.length - effectiveMaxChars + 1)}';
    }
    return preview;
  }

  static String _sanitizePreviewFragment(String text) =>
      text.replaceAll(_previewSanitizerPattern, '').trimRight();

  static String? _sanitizeWindowTitle(String text) {
    final sanitized = text.replaceAll(_windowTitleSanitizerPattern, '').trim();
    return sanitized.isEmpty ? null : sanitized;
  }

  void _notifyPreviewChanged() {
    for (final listener in _previewListeners.toList(growable: false)) {
      listener();
    }
  }

  void _notifyMetadataChanged() {
    for (final listener in _metadataListeners.toList(growable: false)) {
      listener();
    }
    _notifyPreviewChanged();
  }

  /// Execute a command.
  Future<SSHSession> execute(String command, {SSHPtyConfig? pty}) async {
    DiagnosticsLogService.instance.debug(
      'ssh.exec',
      'open_start',
      fields: {
        'connectionId': connectionId,
        'commandKind': _diagnosticSshCommandKind(command),
        'pty': pty != null,
      },
    );
    try {
      final execSession = await client.execute(command, pty: pty);
      DiagnosticsLogService.instance.debug(
        'ssh.exec',
        'open_success',
        fields: {
          'connectionId': connectionId,
          'commandKind': _diagnosticSshCommandKind(command),
          'pty': pty != null,
        },
      );
      return execSession;
    } on Object catch (error) {
      DiagnosticsLogService.instance.error(
        'ssh.exec',
        'open_failed',
        fields: {
          'connectionId': connectionId,
          'commandKind': _diagnosticSshCommandKind(command),
          'pty': pty != null,
          ..._diagnosticSshExecErrorFields(error),
        },
      );
      rethrow;
    }
  }

  /// Runs short-lived exec work through this connection's bounded exec queue.
  ///
  /// The callback should open, consume, and close any SSH exec channel it uses.
  /// Long-lived channels such as the interactive shell and tmux control-mode
  /// watcher should not use this queue because they would permanently occupy a
  /// short-command slot.
  Future<T> runQueuedExec<T>(
    Future<T> Function() operation, {
    SshExecPriority priority = SshExecPriority.normal,
  }) => runQueuedSshExec(connectionId, operation, priority: priority);

  /// Start an SFTP session.
  Future<SftpClient> sftp() => client.sftp();

  /// Start a local port forward tunnel.
  ///
  /// Binds to [localHost]:[localPort] and forwards connections to
  /// [remoteHost]:[remotePort] via the SSH connection.
  Future<bool> startLocalForward({
    required int portForwardId,
    required String localHost,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    if (_activeTunnels.containsKey(portForwardId)) {
      return true; // Already running
    }

    try {
      final serverSocket = await ServerSocket.bind(localHost, localPort);
      final tunnel = _ActiveTunnel.local(
        serverSocket: serverSocket,
        localPort: serverSocket.port,
        remoteHost: remoteHost,
        remotePort: remotePort,
      );

      _activeTunnels[portForwardId] = tunnel;

      // Handle incoming connections
      tunnel.subscription = serverSocket.listen((socket) async {
        SSHForwardChannel? forward;
        try {
          forward = await client.forwardLocal(remoteHost, remotePort);
          // Pipe data bidirectionally and wait until either side finishes.
          final forwardToSocket = forward.stream.cast<List<int>>().pipe(socket);
          final socketToForward = socket.cast<List<int>>().pipe(forward.sink);

          await Future.any<void>([forwardToSocket, socketToForward]);
        } on Exception catch (e) {
          DiagnosticsLogService.instance.warning(
            'ssh.forward',
            'local_connection_failed',
            fields: {'errorType': e.runtimeType},
          );
          if (kDebugMode) {
            debugPrint('Port forward connection error: $e');
          }
        } finally {
          try {
            await forward?.sink.close();
          } on Exception catch (_) {
            // Ignore errors during cleanup.
          }
          try {
            socket.destroy();
          } on Exception catch (_) {
            // Ignore errors during cleanup.
          }
        }
      });

      return true;
    } on Exception catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'local_start_failed',
        fields: {'errorType': e.runtimeType},
      );
      if (kDebugMode) {
        debugPrint('Failed to start local forward: $e');
      }
      return false;
    }
  }

  /// Start a remote port forward tunnel.
  ///
  /// Binds to [remoteHost]:[remotePort] on the SSH server and forwards
  /// incoming connections to [localHost]:[localPort] on this device.
  Future<bool> startRemoteForward({
    required int portForwardId,
    required String remoteHost,
    required int remotePort,
    required String localHost,
    required int localPort,
  }) async {
    if (_activeTunnels.containsKey(portForwardId)) {
      return true;
    }

    try {
      final remoteForward = await client.forwardRemote(
        host: remoteHost,
        port: remotePort,
      );
      if (remoteForward == null) {
        return false;
      }

      final tunnel = _ActiveTunnel.remote(
        remoteForward: remoteForward,
        localPort: localPort,
        remoteHost: remoteForward.host,
        remotePort: remoteForward.port,
      );

      _activeTunnels[portForwardId] = tunnel;
      tunnel.subscription = remoteForward.connections.listen((channel) async {
        Socket? socket;
        try {
          socket = await Socket.connect(localHost, localPort);
          final remoteToLocal = channel.stream.cast<List<int>>().pipe(socket);
          final localToRemote = socket.cast<List<int>>().pipe(channel.sink);
          await Future.any<void>([remoteToLocal, localToRemote]);
        } on Exception catch (e) {
          DiagnosticsLogService.instance.warning(
            'ssh.forward',
            'remote_connection_failed',
            fields: {'errorType': e.runtimeType},
          );
          if (kDebugMode) {
            debugPrint('Remote forward connection error: $e');
          }
        } finally {
          try {
            await channel.sink.close();
          } on Exception catch (_) {
            // Ignore cleanup errors.
          }
          try {
            socket?.destroy();
          } on Exception catch (_) {
            // Ignore cleanup errors.
          }
        }
      });

      return true;
    } on Exception catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'remote_start_failed',
        fields: {'errorType': e.runtimeType},
      );
      if (kDebugMode) {
        debugPrint('Failed to start remote forward: $e');
      }
      return false;
    }
  }

  /// Stop a specific port forward tunnel.
  Future<void> stopForward(int portForwardId) async {
    final tunnel = _activeTunnels.remove(portForwardId);
    if (tunnel != null) {
      await tunnel.subscription?.cancel();
      await tunnel.serverSocket?.close();
      tunnel.remoteForward?.close();
    }
  }

  /// Stop all port forward tunnels.
  Future<void> stopAllForwards() async {
    for (final id in _activeTunnels.keys.toList()) {
      await stopForward(id);
    }
  }

  /// Forward a local port (legacy method for jump hosts).
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) => client.forwardLocal(remoteHost, remotePort);

  /// Close the session.
  Future<void> close() async {
    await stopAllForwards();
    await closeShell();
    client.close();
    for (final dependentClient in dependentClients) {
      dependentClient.close();
    }
  }
}

/// Lightweight active connection metadata for UI.
class ActiveConnection {
  /// Creates a new [ActiveConnection].
  const ActiveConnection({
    required this.connectionId,
    required this.hostId,
    required this.state,
    required this.createdAt,
    required this.config,
    this.preview,
    this.windowTitle,
    this.iconName,
    this.workingDirectory,
    this.shellStatus,
    this.lastExitCode,
    this.terminalThemeLightId,
    this.terminalThemeDarkId,
  });

  /// Connection identifier.
  final int connectionId;

  /// Host identifier.
  final int hostId;

  /// Current connection state.
  final SshConnectionState state;

  /// When this connection was opened.
  final DateTime createdAt;

  /// SSH endpoint details.
  final SshConnectionConfig config;

  /// The latest terminal preview snippet, when available.
  final String? preview;

  /// The latest remote window title, when available.
  final String? windowTitle;

  /// The latest remote icon name, when available.
  final String? iconName;

  /// The latest terminal working-directory URI, when available.
  final Uri? workingDirectory;

  /// The latest shell integration status, when available.
  final TerminalShellStatus? shellStatus;

  /// The latest command exit code emitted through shell integration.
  final int? lastExitCode;

  /// Session-specific light theme override.
  final String? terminalThemeLightId;

  /// Session-specific dark theme override.
  final String? terminalThemeDarkId;
}

/// Info about an active tunnel for UI display.
class ActiveTunnelInfo {
  /// Creates tunnel info.
  const ActiveTunnelInfo({
    required this.portForwardId,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.isLocal,
  });

  /// The port forward database ID.
  final int portForwardId;

  /// The local port being listened on.
  final int localPort;

  /// The remote host being forwarded to.
  final String remoteHost;

  /// The remote port being forwarded to.
  final int remotePort;

  /// Whether this is a local (true) or remote (false) forward.
  final bool isLocal;
}

class _ActiveTunnel {
  _ActiveTunnel.local({
    required this.serverSocket,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
  }) : remoteForward = null,
       isLocal = true;

  _ActiveTunnel.remote({
    required this.remoteForward,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
  }) : serverSocket = null,
       isLocal = false;

  final ServerSocket? serverSocket;
  final SSHRemoteForward? remoteForward;
  final int localPort;
  final String remoteHost;
  final int remotePort;
  final bool isLocal;
  // Cancelled in SshSession.stopForward().
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? subscription;
}

/// Provider for [SshService].
final sshServiceProvider = Provider<SshService>(
  (ref) => SshService(
    hostRepository: ref.watch(hostRepositoryProvider),
    keyRepository: ref.watch(keyRepositoryProvider),
    knownHostsRepository: ref.watch(knownHostsRepositoryProvider),
    hostKeyPromptHandler: ref.watch(hostKeyPromptHandlerProvider),
    wifiNetworkService: ref.watch(wifiNetworkServiceProvider),
  ),
);

/// Provider for tracking active SSH sessions.
final activeSessionsProvider =
    NotifierProvider<ActiveSessionsNotifier, Map<int, SshConnectionState>>(
      ActiveSessionsNotifier.new,
    );

/// Notifier for active SSH sessions state.
class ActiveSessionsNotifier extends Notifier<Map<int, SshConnectionState>> {
  static const _previewStateRefreshInterval = Duration(milliseconds: 150);

  late final SshService _sshService;
  final Map<int, int> _connectionHostIds = {};
  final Map<int, ConnectionAttemptStatus> _connectionAttempts = {};
  final Map<int, StreamSubscription<void>> _disconnectSubscriptions = {};
  Timer? _previewStateRefreshTimer;
  bool _previewStateRefreshQueued = false;
  Future<void> _backgroundStatusSyncQueue = Future<void>.value();

  @override
  Map<int, SshConnectionState> build() {
    _sshService = ref.watch(sshServiceProvider);
    ref.onDispose(() {
      _previewStateRefreshTimer?.cancel();
      _previewStateRefreshTimer = null;
      _previewStateRefreshQueued = false;
      for (final subscription in _disconnectSubscriptions.values) {
        unawaited(subscription.cancel());
      }
      _disconnectSubscriptions.clear();
    });
    _connectionHostIds.clear();
    _connectionAttempts.clear();
    return {};
  }

  /// Connect to a host.
  Future<SshConnectionResult> connect(
    int hostId, {
    bool forceNew = false,
    bool useHostThemeOverrides = true,
  }) async {
    if (!forceNew) {
      final existingConnectionId = getPreferredConnectionForHost(hostId);
      if (existingConnectionId != null) {
        DiagnosticsLogService.instance.info(
          'ssh.active',
          'reuse_connection',
          fields: {'hostId': hostId, 'connectionId': existingConnectionId},
        );
        unawaited(_queueBackgroundStatusSync());
        return SshConnectionResult(
          success: true,
          connectionId: existingConnectionId,
          reusedConnection: true,
        );
      }
    }

    _updateConnectionAttempt(
      hostId,
      const ConnectionProgressUpdate(
        state: SshConnectionState.connecting,
        message: 'Preparing connection…',
      ),
      resetLog: true,
    );

    final result = await _sshService.connectToHost(
      hostId,
      onProgress: (update) => _updateConnectionAttempt(hostId, update),
      useHostThemeOverrides: useHostThemeOverrides,
    );

    if (result.success && result.connectionId != null) {
      final connectionId = result.connectionId!;
      _connectionHostIds[connectionId] = hostId;
      final session = _sshService.getSession(connectionId);
      if (session != null) {
        _attachSessionListeners(session);
      }
      state = {...state, connectionId: SshConnectionState.connected};
      _updateConnectionAttempt(
        hostId,
        const ConnectionProgressUpdate(
          state: SshConnectionState.connected,
          message: 'Connection established. Opening terminal…',
        ),
      );
      unawaited(_queueBackgroundStatusSync());
    } else {
      _updateConnectionAttempt(
        hostId,
        ConnectionProgressUpdate(
          state: SshConnectionState.error,
          message: result.error ?? 'Connection failed',
        ),
      );
    }

    DiagnosticsLogService.instance.info(
      'ssh.active',
      'connect_result',
      fields: {
        'hostId': hostId,
        'success': result.success,
        'connectionId': result.connectionId,
        'errorType': _diagnosticSshResultErrorKind(result.error),
      },
    );
    return result;
  }

  /// Disconnect from a connection.
  Future<void> disconnect(int connectionId) async {
    DiagnosticsLogService.instance.info(
      'ssh.active',
      'disconnect',
      fields: {'connectionId': connectionId},
    );
    _detachSessionListeners(connectionId);
    await _sshService.disconnect(connectionId);
    _connectionHostIds.remove(connectionId);
    final next = {...state}..remove(connectionId);
    state = next;
    await _queueBackgroundStatusSync();
  }

  /// Disconnect all active sessions.
  Future<void> disconnectAll() async {
    DiagnosticsLogService.instance.info(
      'ssh.active',
      'disconnect_all',
      fields: {'connectionCount': _sshService.sessions.length},
    );
    for (final session in _sshService.sessions.values) {
      _detachSessionListeners(session.connectionId, session: session);
    }
    await _sshService.disconnectAll();
    _connectionHostIds.clear();
    _connectionAttempts.clear();
    state = {};
    await _queueBackgroundStatusSync();
  }

  /// Get the state of a connection.
  SshConnectionState getState(int connectionId) =>
      state[connectionId] ?? SshConnectionState.disconnected;

  /// Get a session.
  SshSession? getSession(int connectionId) =>
      _sshService.getSession(connectionId);

  /// Get active connection metadata for a single connection.
  ActiveConnection? getActiveConnection(int connectionId) {
    final session = _sshService.getSession(connectionId);
    final hostId = _connectionHostIds[connectionId];
    final connectionState = state[connectionId];
    if (session == null || hostId == null || connectionState == null) {
      return null;
    }
    return ActiveConnection(
      connectionId: connectionId,
      hostId: hostId,
      state: connectionState,
      createdAt: session.createdAt,
      config: session.config,
      preview: session.terminalPreview,
      windowTitle: session.windowTitle,
      iconName: session.iconName,
      workingDirectory: session.workingDirectory,
      shellStatus: session.shellStatus,
      lastExitCode: session.lastExitCode,
      terminalThemeLightId: session.terminalThemeLightId,
      terminalThemeDarkId: session.terminalThemeDarkId,
    );
  }

  /// Get the current connection attempt state for a host.
  ConnectionAttemptStatus? getConnectionAttempt(int hostId) =>
      _connectionAttempts[hostId];

  /// Get all active connection IDs for a host.
  List<int> getConnectionsForHost(int hostId) {
    final matches = <SshSession>[];
    for (final session in _sshService.sessions.values) {
      if (session.hostId == hostId) {
        matches.add(session);
      }
    }
    matches.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return matches
        .map((session) => session.connectionId)
        .toList(growable: false);
  }

  /// Get a preferred existing connection ID for a host.
  int? getPreferredConnectionForHost(int hostId) {
    final activeConnections = <SshSession>[];
    for (final session in _sshService.sessions.values) {
      final connectionId = session.connectionId;
      final sessionHostId = _connectionHostIds[connectionId];
      final connectionState = state[connectionId];
      if (sessionHostId == hostId &&
          connectionState != null &&
          connectionState != SshConnectionState.error &&
          connectionState != SshConnectionState.disconnected) {
        activeConnections.add(session);
      }
    }
    if (activeConnections.isEmpty) {
      return null;
    }
    activeConnections.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return activeConnections.first.connectionId;
  }

  /// Get all active connection metadata for UI rendering.
  List<ActiveConnection> getActiveConnections() {
    final connections = <ActiveConnection>[];
    for (final entry in state.entries) {
      final connectionId = entry.key;
      final session = _sshService.getSession(connectionId);
      final hostId = _connectionHostIds[connectionId];
      if (session == null || hostId == null) {
        continue;
      }
      connections.add(
        ActiveConnection(
          connectionId: connectionId,
          hostId: hostId,
          state: entry.value,
          createdAt: session.createdAt,
          config: session.config,
          preview: session.terminalPreview,
          windowTitle: session.windowTitle,
          iconName: session.iconName,
          workingDirectory: session.workingDirectory,
          shellStatus: session.shellStatus,
          lastExitCode: session.lastExitCode,
          terminalThemeLightId: session.terminalThemeLightId,
          terminalThemeDarkId: session.terminalThemeDarkId,
        ),
      );
    }
    connections.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return connections;
  }

  /// Clear the current connection attempt state for a host.
  void clearConnectionAttempt(int hostId) {
    if (_connectionAttempts.remove(hostId) != null) {
      state = {...state};
    }
  }

  void _attachSessionListeners(SshSession session) {
    session
      ..removePreviewListener(_schedulePreviewStateRefresh)
      ..addPreviewListener(_schedulePreviewStateRefresh);
    final existingSubscription = _disconnectSubscriptions.remove(
      session.connectionId,
    );
    if (existingSubscription != null) {
      unawaited(existingSubscription.cancel());
    }
    _disconnectSubscriptions[session.connectionId] = session.client.done
        .asStream()
        .listen(
          (_) => unawaited(
            handleUnexpectedDisconnect(
              session.connectionId,
              message: 'Connection closed',
            ),
          ),
          onError: (Object error, StackTrace _) => unawaited(
            handleUnexpectedDisconnect(
              session.connectionId,
              message: 'Connection lost: $error',
            ),
          ),
        );
  }

  void _detachSessionListeners(int connectionId, {SshSession? session}) {
    (session ?? _sshService.getSession(connectionId))?.removePreviewListener(
      _schedulePreviewStateRefresh,
    );
    final subscription = _disconnectSubscriptions.remove(connectionId);
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
  }

  void _schedulePreviewStateRefresh() {
    if (!ref.mounted) {
      return;
    }
    if (_previewStateRefreshTimer?.isActive ?? false) {
      _previewStateRefreshQueued = true;
      return;
    }
    _previewStateRefreshTimer = Timer(_previewStateRefreshInterval, () {
      _previewStateRefreshTimer = null;
      if (!ref.mounted) {
        _previewStateRefreshQueued = false;
        return;
      }
      final shouldReschedule = _previewStateRefreshQueued;
      _previewStateRefreshQueued = false;
      state = {...state};
      if (shouldReschedule) {
        _schedulePreviewStateRefresh();
      }
    });
  }

  void _updateConnectionAttempt(
    int hostId,
    ConnectionProgressUpdate update, {
    bool resetLog = false,
  }) {
    final existing = resetLog ? null : _connectionAttempts[hostId];
    final nextLogLines = <String>[if (existing != null) ...existing.logLines];
    if (nextLogLines.isEmpty || nextLogLines.last != update.message) {
      nextLogLines.add(update.message);
    }
    if (nextLogLines.length > 8) {
      nextLogLines.removeRange(0, nextLogLines.length - 8);
    }

    _connectionAttempts[hostId] = ConnectionAttemptStatus(
      hostId: hostId,
      state: update.state,
      latestMessage: update.message,
      logLines: List.unmodifiable(nextLogLines),
    );
    DiagnosticsLogService.instance.info(
      'ssh.active',
      'attempt_update',
      fields: {'hostId': hostId, 'state': update.state},
    );
    state = {...state};
  }

  /// Surface an unexpected connection failure in the shared attempt state.
  void reportConnectionAttemptError(int hostId, String message) {
    _updateConnectionAttempt(
      hostId,
      ConnectionProgressUpdate(
        state: SshConnectionState.error,
        message: message,
      ),
    );
  }

  /// Remove a connection that closed outside the normal user disconnect path.
  Future<void> handleUnexpectedDisconnect(
    int connectionId, {
    required String message,
  }) async {
    final hostId = _connectionHostIds[connectionId];
    final session = _sshService.getSession(connectionId);
    if (hostId == null && session == null && !state.containsKey(connectionId)) {
      DiagnosticsLogService.instance.debug(
        'ssh.active',
        'unexpected_disconnect_ignored',
        fields: {'connectionId': connectionId},
      );
      return;
    }

    DiagnosticsLogService.instance.warning(
      'ssh.active',
      'unexpected_disconnect',
      fields: {'connectionId': connectionId, 'hostId': hostId},
    );
    _detachSessionListeners(connectionId, session: session);
    await _sshService.disconnect(connectionId);
    _connectionHostIds.remove(connectionId);
    final next = {...state}..remove(connectionId);
    state = next;
    if (hostId != null) {
      reportConnectionAttemptError(hostId, message);
    } else {
      state = {...state};
    }
    await _queueBackgroundStatusSync();
  }

  /// Update the session-specific terminal theme for an active connection.
  void updateSessionTheme(
    int connectionId,
    String themeId, {
    required bool isDark,
  }) {
    final session = _sshService.getSession(connectionId);
    if (session == null) {
      return;
    }
    final changed = session.setTerminalThemeId(themeId, isDark: isDark);
    if (!changed) {
      return;
    }
    state = {...state};
  }

  /// Update the session-specific terminal font size for an active connection.
  void updateSessionFontSize(int connectionId, double fontSize) {
    final session = _sshService.getSession(connectionId);
    if (session == null) {
      return;
    }
    session.terminalFontSize = fontSize;
    state = {...state};
  }

  /// Update clipboard sharing on all active sessions.
  void updateClipboardSharing({
    required bool enabled,
    required bool allowLocalClipboardRead,
  }) {
    for (final session in _sshService.allSessions) {
      session
        ..clipboardSharingEnabled = enabled
        ..localClipboardReadEnabled = allowLocalClipboardRead;
    }
  }

  Future<void> _syncBackgroundStatus() async {
    final connections = getActiveConnections();
    if (connections.isEmpty) {
      await BackgroundSshService.stop();
      return;
    }

    final connectedCount = connections
        .where((connection) => connection.state == SshConnectionState.connected)
        .length;

    await BackgroundSshService.updateStatus(
      connectionCount: connections.length,
      connectedCount: connectedCount,
    );
  }

  /// Publish the current active-connection status to native keepalive surfaces.
  Future<void> syncBackgroundStatus() => _queueBackgroundStatusSync();

  Future<void> _queueBackgroundStatusSync() {
    final nextSync = _backgroundStatusSyncQueue
        .catchError((Object _) {})
        .then((_) => _syncBackgroundStatus());
    _backgroundStatusSyncQueue = nextSync;
    return nextSync;
  }
}
