import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/monkeymux_acp_bridge.dart';
import 'acp_transport.dart';
import 'diagnostics_log_service.dart';
import 'monkeymux_installer_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'windows_remote_powershell.dart';

const _metadataMaxBytes = 64 * 1024;
const _maxBridgeListEntries = 1024;
const _helperTimeout = Duration(seconds: 15);
const _profileSourcingPrefix =
    r'export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; '
    '{ . ~/.profile; . ~/.bash_profile; . ~/.zprofile; } >/dev/null 2>&1; '
    r'export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/homebrew/bin:$HOME/homebrew/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"; ';
final _bridgeIdPattern = RegExp(r'^[a-f0-9]{32}$');
final _commandHashPattern = RegExp(r'^[a-f0-9]{64}$');

/// Provides persistent MonkeyMux ACP bridge lifecycle operations.
final monkeyMuxAcpBridgeServiceProvider = Provider<MonkeyMuxAcpBridgeService>(
  (ref) => MonkeyMuxAcpBridgeService(
    installer: ref.watch(monkeyMuxInstallerServiceProvider),
  ),
);

/// Returns whether [bridgeId] is a valid opaque MonkeyMux ACP identifier.
bool isValidMonkeyMuxAcpBridgeId(String bridgeId) =>
    _bridgeIdPattern.hasMatch(bridgeId);

/// Builds the exact approved provider argv as one remote shell command.
///
/// POSIX uses the app's established profile/PATH prefix. Windows uses the
/// established encoded PowerShell convention so every argv element remains a
/// separate literal even when the login shell is `cmd.exe`.
String buildMonkeyMuxAcpProviderCommand(
  List<String> launchArgv, {
  required bool isWindows,
}) {
  if (launchArgv.isEmpty ||
      launchArgv.first.trim().isEmpty ||
      launchArgv.any((value) => value.contains('\u0000'))) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidLaunch,
      'The approved provider launch arguments are invalid.',
    );
  }
  const executableVariable = r'$__flAcpExe';
  const argumentsVariable = r'$__flAcpArgs';
  const argumentsSplat = '@__flAcpArgs';
  final windowsScript = [
    r"$ErrorActionPreference='Stop';",
    '$executableVariable=${powerShellSingleQuote(launchArgv.first)};',
    '$argumentsVariable=@(',
    launchArgv.skip(1).map(powerShellSingleQuote).join(','),
    ');',
    '& $executableVariable $argumentsSplat;',
    r'if($null -ne $LASTEXITCODE){exit $LASTEXITCODE}',
  ].join();
  final command = isWindows
      ? buildWindowsPowerShellCommand(windowsScript)
      : '$_profileSourcingPrefix'
            '${launchArgv.map(_posixShellQuote).join(' ')}';
  if (utf8.encode(command).length > 8192) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidLaunch,
      'The approved provider launch command is too large.',
    );
  }
  return command;
}

/// Installs and controls persistent MonkeyMux ACP bridges over SSH.
final class MonkeyMuxAcpBridgeService {
  /// Creates a bridge service.
  MonkeyMuxAcpBridgeService({
    required MonkeyMuxInstallerService installer,
    DiagnosticsLogger? diagnostics,
  }) : _installer = installer,
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance;

  final MonkeyMuxInstallerService _installer;
  final DiagnosticsLogger _diagnostics;

  /// Starts a persistent bridge using the exact approved [launchArgv].
  Future<MonkeyMuxAcpBridgeStartResult> start({
    required SshSession session,
    required String providerId,
    required String providerLabel,
    required List<String> launchArgv,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    _validateLaunch(providerId, providerLabel, cwd);
    final installation = await _installer.ensureInstalled(
      session,
      priority: SshExecPriority.normal,
      confirmInstall: confirmInstall,
    );
    final providerCommand = buildMonkeyMuxAcpProviderCommand(
      launchArgv,
      isWindows: installation.isWindows,
    );
    final startedAt = DateTime.now();
    try {
      final message = await _runHelper(session, installation, [
        'acp',
        'start',
        '--provider',
        providerLabel,
        '--command',
        providerCommand,
        '--cwd',
        cwd,
      ]);
      _requireType(message, 'started');
      final bridgeId = _readBridgeId(message['bridgeId']);
      _diagnostics.info(
        'acp.bridge',
        'start_success',
        fields: {
          'connectionId': session.connectionId,
          'providerHash': _providerHash(providerId),
          'bridgeId': bridgeId,
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
        },
      );
      return MonkeyMuxAcpBridgeStartResult(bridgeId: bridgeId);
    } on Object catch (error, stackTrace) {
      _diagnostics.error(
        'acp.bridge',
        'start_failed',
        fields: {
          'connectionId': session.connectionId,
          'providerHash': _providerHash(providerId),
          'errorType': error.runtimeType,
          if (error is MonkeyMuxAcpBridgeException)
            'bridgeErrorKind': error.kind.name,
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
        },
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Lists running bridges using only the helper's safe metadata schema.
  Future<List<MonkeyMuxAcpBridgeMetadata>> list(
    SshSession session, {
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    final installation = await _installer.ensureInstalled(
      session,
      priority: SshExecPriority.normal,
      confirmInstall: confirmInstall,
    );
    final message = await _runHelper(session, installation, const [
      'acp',
      'list',
    ]);
    _requireType(message, 'list');
    final rawBridges = message['bridges'];
    if (rawBridges is! List || rawBridges.length > _maxBridgeListEntries) {
      throw const MonkeyMuxAcpBridgeException(
        MonkeyMuxAcpBridgeErrorKind.invalidMetadata,
        'The helper returned invalid bridge metadata.',
      );
    }
    final bridges = rawBridges
        .map(_parseBridgeMetadata)
        .toList(growable: false);
    _diagnostics.debug(
      'acp.bridge',
      'list_success',
      fields: {'connectionId': session.connectionId, 'count': bridges.length},
    );
    return bridges;
  }

  /// Reads safe metadata for [bridgeId].
  Future<MonkeyMuxAcpBridgeMetadata> status(
    SshSession session,
    String bridgeId,
  ) async {
    _validateBridgeId(bridgeId);
    final installation = await _installer.ensureInstalled(session);
    final message = await _runHelper(session, installation, [
      'acp',
      'status',
      bridgeId,
    ]);
    _requireType(message, 'status');
    final bridge = _parseBridgeMetadata(message['bridge']);
    if (bridge.id != bridgeId) {
      throw const MonkeyMuxAcpBridgeException(
        MonkeyMuxAcpBridgeErrorKind.invalidMetadata,
        'The helper returned metadata for a different bridge.',
      );
    }
    return bridge;
  }

  /// Explicitly stops the remote provider and bridge.
  Future<void> stop(SshSession session, String bridgeId) async {
    _validateBridgeId(bridgeId);
    final installation = await _installer.ensureInstalled(
      session,
      priority: SshExecPriority.normal,
    );
    final message = await _runHelper(session, installation, [
      'acp',
      'stop',
      bridgeId,
    ]);
    _requireType(message, 'stopping');
    if (_readBridgeId(message['bridgeId']) != bridgeId) {
      throw const MonkeyMuxAcpBridgeException(
        MonkeyMuxAcpBridgeErrorKind.invalidFrame,
        'The helper stopped a different bridge.',
      );
    }
    _diagnostics.info(
      'acp.bridge',
      'stop_success',
      fields: {'connectionId': session.connectionId, 'bridgeId': bridgeId},
    );
  }

  /// Creates a reconnecting ACP byte transport for an existing bridge.
  MonkeyMuxAcpTransport connect({
    required Future<SshSession> Function() sessionProvider,
    required String bridgeId,
    required String providerId,
    List<Duration> reconnectBackoff = const [
      Duration(milliseconds: 200),
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    Duration handshakeTimeout = const Duration(seconds: 10),
  }) {
    _validateBridgeId(bridgeId);
    return MonkeyMuxAcpTransport._(
      installer: _installer,
      sessionProvider: sessionProvider,
      bridgeId: bridgeId,
      providerHash: _providerHash(providerId),
      diagnostics: _diagnostics,
      reconnectBackoff: reconnectBackoff,
      handshakeTimeout: handshakeTimeout,
    );
  }

  Future<Map<String, Object?>> _runHelper(
    SshSession session,
    MonkeyMuxInstallation installation,
    List<String> arguments,
  ) => session.runQueuedExec(() async {
    SSHSession? channel;
    StreamSubscription<Uint8List>? stderrSubscription;
    try {
      channel = await session.execute(
        _buildHelperCommand(installation, arguments),
      );
      stderrSubscription = channel.stderr.listen(
        (_) {},
        onError: _ignoreStreamError,
      );
      final bytes = <int>[];
      await for (final chunk in channel.stdout.timeout(_helperTimeout)) {
        bytes.addAll(chunk);
        if (bytes.length > _metadataMaxBytes) {
          throw const MonkeyMuxAcpBridgeException(
            MonkeyMuxAcpBridgeErrorKind.invalidMetadata,
            'The helper response exceeded the metadata limit.',
          );
        }
      }
      if (bytes.isEmpty) {
        throw const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.helperProcess,
          'The helper closed without a response.',
        );
      }
      return _decodeSingleFrame(bytes, maxBytes: _metadataMaxBytes);
    } on MonkeyMuxAcpBridgeException {
      rethrow;
    } on Object catch (error) {
      throw MonkeyMuxAcpBridgeException(
        MonkeyMuxAcpBridgeErrorKind.helperUnavailable,
        'The helper command failed (${error.runtimeType}).',
      );
    } finally {
      await stderrSubscription?.cancel();
      channel?.close();
    }
  });
}

/// Reconnecting MonkeyMux bridge transport that exposes only ACP NDJSON bytes.
final class MonkeyMuxAcpTransport implements AcpTransport {
  MonkeyMuxAcpTransport._({
    required MonkeyMuxInstallerService installer,
    required Future<SshSession> Function() sessionProvider,
    required String bridgeId,
    required String providerHash,
    required DiagnosticsLogger diagnostics,
    required List<Duration> reconnectBackoff,
    required Duration handshakeTimeout,
  }) : _installer = installer,
       _sessionProvider = sessionProvider,
       _bridgeId = bridgeId,
       _providerHash = providerHash,
       _diagnostics = diagnostics,
       _reconnectBackoff = List.unmodifiable(reconnectBackoff),
       _handshakeTimeout = handshakeTimeout {
    scheduleMicrotask(() {
      _emitState(MonkeyMuxAcpTransportStatus.connecting);
      unawaited(_openChannel());
    });
  }

  final MonkeyMuxInstallerService _installer;
  final Future<SshSession> Function() _sessionProvider;
  final String _bridgeId;
  final String _providerHash;
  final DiagnosticsLogger _diagnostics;
  final List<Duration> _reconnectBackoff;
  final Duration _handshakeTimeout;
  final _incoming = StreamController<List<int>>(sync: true);
  final _states = StreamController<MonkeyMuxAcpTransportState>.broadcast(
    sync: true,
  );
  final _errors = StreamController<MonkeyMuxAcpBridgeException>.broadcast(
    sync: true,
  );
  final _wireFrame = <int>[];
  final _outgoingFrame = <int>[];
  final _pendingInputFrames = Queue<Uint8List>();

  SSHSession? _channel;
  StreamSubscription<Uint8List>? _stdoutSubscription;
  StreamSubscription<Uint8List>? _stderrSubscription;
  Timer? _reconnectTimer;
  Timer? _handshakeTimer;
  Future<void>? _closeFuture;
  Future<void>? _releaseFuture;
  var _generation = 0;
  var _reconnectAttempt = 0;
  var _lastDeliveredSequence = 0;
  var _connected = false;
  var _closed = false;
  var _terminalFailure = false;
  int? _handshakeHighWaterSequence;
  int? _replayWindowRetainedFrom;
  int? _replayWindowHighWaterSequence;

  /// Typed connection lifecycle updates.
  Stream<MonkeyMuxAcpTransportState> get states => _states.stream;

  /// Typed bridge errors kept separate from raw ACP bytes.
  Stream<MonkeyMuxAcpBridgeException> get errors => _errors.stream;

  /// Opaque remote bridge identifier.
  String get bridgeId => _bridgeId;

  /// Latest bridge event sequence delivered and acknowledged.
  int get lastDeliveredSequence => _lastDeliveredSequence;

  /// Whether the writer handshake completed.
  bool get isConnected => _connected;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> write(List<int> bytes) async {
    if (_closed || _terminalFailure) {
      throw const MonkeyMuxAcpBridgeException(
        MonkeyMuxAcpBridgeErrorKind.closed,
        'The ACP bridge transport is closed.',
      );
    }
    for (final byte in bytes) {
      if (byte == 0x0a) {
        final frame = List<int>.of(_outgoingFrame);
        _outgoingFrame.clear();
        if (frame.isNotEmpty && frame.last == 0x0d) frame.removeLast();
        if (frame.isEmpty) continue;
        _validateAcpInputFrame(frame);
        _pendingInputFrames.add(Uint8List.fromList(frame));
        continue;
      }
      _outgoingFrame.add(byte);
      if (_outgoingFrame.length > monkeyMuxAcpBridgeMaxFrameBytes) {
        _outgoingFrame.clear();
        throw const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.frameTooLarge,
          'The ACP input frame exceeded the bridge limit.',
        );
      }
    }
    _flushPendingInput();
  }

  @override
  Future<void> close() => _closeFuture ??= _closeLocal();

  Future<void> _openChannel() async {
    if (_closed || _terminalFailure) return;
    final generation = ++_generation;
    SshSession? session;
    SSHSession? channel;
    try {
      session = await _sessionProvider();
      final installation = await _installer.ensureInstalled(
        session,
        priority: SshExecPriority.normal,
      );
      if (_closed || _terminalFailure || generation != _generation) return;
      channel = await session.execute(
        _buildHelperCommand(installation, ['acp', 'connect', _bridgeId]),
      );
      if (_closed || _terminalFailure || generation != _generation) {
        channel.close();
        return;
      }
      _channel = channel;
      _stdoutSubscription = channel.stdout.listen(
        (bytes) => _handleWireBytes(bytes, generation),
        onError: (Object error, StackTrace stackTrace) =>
            _handleChannelLoss(generation, error),
        onDone: () => _handleChannelLoss(generation, null),
        cancelOnError: false,
      );
      _stderrSubscription = channel.stderr.listen(
        (_) {},
        onError: _ignoreStreamError,
      );
      _handshakeTimer?.cancel();
      _handshakeTimer = Timer(
        _handshakeTimeout,
        () => _handleChannelLoss(
          generation,
          TimeoutException('ACP bridge handshake timed out'),
        ),
      );
      _sendWire({
        'version': monkeyMuxAcpBridgeProtocolVersion,
        'type': 'hello',
        'bridgeId': _bridgeId,
        'lastAck': _lastDeliveredSequence,
      });
      _diagnostics.debug(
        'acp.transport',
        'attach_opened',
        fields: {
          'connectionId': session.connectionId,
          'providerHash': _providerHash,
          'bridgeId': _bridgeId,
          'attempt': _reconnectAttempt,
          'sequence': _lastDeliveredSequence,
        },
      );
    } on Object catch (error) {
      channel?.close();
      if (generation == _generation && !_closed && !_terminalFailure) {
        _scheduleReconnect(error);
      }
    }
  }

  void _handleWireBytes(Uint8List bytes, int generation) {
    if (generation != _generation || _closed || _terminalFailure) return;
    for (final byte in bytes) {
      if (byte == 0x0a) {
        final frame = List<int>.of(_wireFrame);
        _wireFrame.clear();
        if (frame.isNotEmpty && frame.last == 0x0d) frame.removeLast();
        if (frame.isNotEmpty) _handleWireFrame(frame);
        if (_closed || _terminalFailure) return;
        continue;
      }
      _wireFrame.add(byte);
      if (_wireFrame.length > monkeyMuxAcpBridgeMaxFrameBytes) {
        _wireFrame.clear();
        _failTerminal(
          const MonkeyMuxAcpBridgeException(
            MonkeyMuxAcpBridgeErrorKind.frameTooLarge,
            'A bridge frame exceeded the protocol limit.',
          ),
        );
        return;
      }
    }
  }

  void _handleWireFrame(List<int> bytes) {
    Map<String, Object?> message;
    try {
      message = _decodeSingleFrame(
        bytes,
        maxBytes: monkeyMuxAcpBridgeMaxFrameBytes,
      );
    } on MonkeyMuxAcpBridgeException catch (error) {
      _failTerminal(error);
      return;
    }
    if (message['version'] != monkeyMuxAcpBridgeProtocolVersion) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.unsupportedVersion,
          'The helper uses an unsupported ACP bridge protocol version.',
        ),
      );
      return;
    }
    final type = message['type'];
    if (type is! String) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidFrame,
          'The helper returned an invalid bridge frame.',
        ),
      );
      return;
    }
    if ((type == 'hello' || type == 'status') &&
        bytes.length > _metadataMaxBytes) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidMetadata,
          'The bridge metadata exceeded its limit.',
        ),
      );
      return;
    }
    switch (type) {
      case 'hello':
        _handleHello(message);
      case 'output':
        _handleOutput(message);
      case 'state':
        _handleProviderState(message);
      case 'overflow':
        _handleOverflow(message);
      case 'status':
        final metadata = _parseBridgeMetadata(message['bridge']);
        _emitState(
          _connected
              ? MonkeyMuxAcpTransportStatus.connected
              : MonkeyMuxAcpTransportStatus.connecting,
          providerState: metadata.state,
        );
      case 'error':
        _handleBridgeError(message);
      default:
        _failTerminal(
          const MonkeyMuxAcpBridgeException(
            MonkeyMuxAcpBridgeErrorKind.invalidFrame,
            'The helper returned an unknown bridge frame type.',
          ),
        );
    }
  }

  void _handleHello(Map<String, Object?> message) {
    final returnedBridgeId = _readBridgeId(message['bridgeId']);
    if (returnedBridgeId != _bridgeId) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidBridgeId,
          'The helper attached to a different ACP bridge.',
        ),
      );
      return;
    }
    final metadata = _parseBridgeMetadata(message['bridge']);
    if (metadata.id != _bridgeId) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidMetadata,
          'The bridge handshake metadata did not match.',
        ),
      );
      return;
    }
    if (message['canSend'] != true) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.nonWriter,
          'Another client is already attached as the ACP writer.',
        ),
      );
      return;
    }
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _connected = true;
    _reconnectAttempt = 0;
    if (metadata.nextSequence < _lastDeliveredSequence) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.sequenceGap,
          'The bridge handshake sequence regressed.',
        ),
      );
      return;
    }
    _handshakeHighWaterSequence = metadata.nextSequence;
    _replayWindowRetainedFrom = null;
    _replayWindowHighWaterSequence = null;
    if (metadata.state == MonkeyMuxAcpProviderState.exited ||
        metadata.state == MonkeyMuxAcpProviderState.stopped) {
      _emitState(
        MonkeyMuxAcpTransportStatus.providerExited,
        providerState: metadata.state,
      );
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.providerExited,
          'The remote ACP provider exited.',
        ),
        emitFailedState: false,
      );
      return;
    }
    _emitState(
      MonkeyMuxAcpTransportStatus.connected,
      providerState: metadata.state,
    );
    _flushPendingInput();
  }

  void _handleOutput(Map<String, Object?> message) {
    if (!_matchesCurrentBridge(message)) return;
    if (!_connected) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidFrame,
          'ACP output arrived before the bridge handshake.',
        ),
      );
      return;
    }
    final sequence = _readNonNegativeInt(message['sequence']);
    if (sequence == null || sequence == 0) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidFrame,
          'The helper returned an invalid output sequence.',
        ),
      );
      return;
    }
    if (!_sequenceIsAcceptable(sequence)) return;
    final data = message['data'];
    if (data is! Map) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidFrame,
          'The bridge output did not contain an ACP JSON object.',
        ),
      );
      return;
    }
    final encoded = utf8.encode('${jsonEncode(data)}\n');
    if (encoded.length > monkeyMuxAcpBridgeMaxFrameBytes) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.frameTooLarge,
          'The unwrapped ACP frame exceeded the protocol limit.',
        ),
      );
      return;
    }
    _commitSequence(sequence);
    _incoming.add(encoded);
    _sendAck(sequence);
  }

  void _handleProviderState(Map<String, Object?> message) {
    if (!_matchesCurrentBridge(message)) return;
    final sequence = _readNonNegativeInt(message['sequence']);
    if (sequence == null || sequence == 0) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidFrame,
          'The helper returned an invalid provider-state sequence.',
        ),
      );
      return;
    }
    final rawState = message['state'];
    if (rawState is! String || rawState.length > 32) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidFrame,
          'The helper returned an invalid provider state.',
        ),
      );
      return;
    }
    final state = _parseProviderState(rawState);
    final rawExitCode = message['exitCode'];
    final exitCode = rawExitCode is int ? rawExitCode : null;
    if (!_sequenceIsAcceptable(sequence)) return;
    _commitSequence(sequence);
    _sendAck(sequence);
    if (state == MonkeyMuxAcpProviderState.exited ||
        state == MonkeyMuxAcpProviderState.stopped) {
      _emitState(
        MonkeyMuxAcpTransportStatus.providerExited,
        providerState: state,
        exitCode: exitCode,
      );
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.providerExited,
          'The remote ACP provider exited.',
        ),
        emitFailedState: false,
        exitCode: exitCode,
      );
      return;
    }
    if (state == MonkeyMuxAcpProviderState.protocolError) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidFrame,
          'The provider emitted invalid ACP protocol data.',
        ),
      );
      return;
    }
    _emitState(
      _connected
          ? MonkeyMuxAcpTransportStatus.connected
          : MonkeyMuxAcpTransportStatus.connecting,
      providerState: state,
      exitCode: exitCode,
    );
  }

  void _handleOverflow(Map<String, Object?> message) {
    if (!_matchesCurrentBridge(message)) return;
    final retainedFrom = _readNonNegativeInt(message['retainedFrom']);
    if (retainedFrom == null || retainedFrom == 0) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidFrame,
          'The helper returned invalid replay overflow metadata.',
        ),
      );
      return;
    }
    final highWater = _handshakeHighWaterSequence;
    if (highWater == null ||
        retainedFrom > highWater ||
        highWater < _lastDeliveredSequence ||
        _replayWindowHighWaterSequence != null) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.sequenceGap,
          'The helper returned an invalid replay window.',
        ),
      );
      return;
    }
    if (highWater > _lastDeliveredSequence) {
      _replayWindowRetainedFrom = retainedFrom;
      _replayWindowHighWaterSequence = highWater;
    }
    const error = MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.replayOverflow,
      'Some detached ACP output is no longer retained.',
    );
    _errors.add(error);
    _emitState(
      _connected
          ? MonkeyMuxAcpTransportStatus.connected
          : MonkeyMuxAcpTransportStatus.connecting,
      retainedFrom: retainedFrom,
    );
  }

  void _handleBridgeError(Map<String, Object?> message) {
    final errorText = message['error'];
    if (errorText is! String || errorText.length > 256) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.invalidFrame,
          'The helper returned an invalid bridge error.',
        ),
      );
      return;
    }
    if (errorText == 'ACP bridge is attached by another writer') {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.nonWriter,
          'Another client is already attached as the ACP writer.',
        ),
      );
      return;
    }
    if (errorText == 'ACP provider is unavailable') {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.providerUnavailable,
          'The remote ACP provider is unavailable.',
        ),
      );
      return;
    }
    if (errorText == 'unsupported ACP bridge protocol') {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.unsupportedVersion,
          'The helper rejected the ACP bridge protocol version.',
        ),
      );
      return;
    }
    _failTerminal(
      const MonkeyMuxAcpBridgeException(
        MonkeyMuxAcpBridgeErrorKind.invalidFrame,
        'The helper rejected a bridge protocol message.',
      ),
    );
  }

  bool _sequenceIsAcceptable(int sequence) {
    final replayHighWater = _replayWindowHighWaterSequence;
    if (replayHighWater != null) {
      final retainedFrom = _replayWindowRetainedFrom!;
      if (sequence <= _lastDeliveredSequence ||
          sequence < retainedFrom ||
          sequence > replayHighWater) {
        _failTerminal(
          const MonkeyMuxAcpBridgeException(
            MonkeyMuxAcpBridgeErrorKind.sequenceGap,
            'The bridge replay sequence was outside its announced window.',
          ),
        );
        return false;
      }
      return true;
    }
    if (sequence <= _lastDeliveredSequence) {
      _sendAck(_lastDeliveredSequence);
      return false;
    }
    if (sequence != _lastDeliveredSequence + 1) {
      _failTerminal(
        const MonkeyMuxAcpBridgeException(
          MonkeyMuxAcpBridgeErrorKind.sequenceGap,
          'The live bridge sequence contained an unexplained gap.',
        ),
      );
      return false;
    }
    return true;
  }

  void _commitSequence(int sequence) {
    _lastDeliveredSequence = sequence;
    if (sequence == _replayWindowHighWaterSequence) {
      _replayWindowRetainedFrom = null;
      _replayWindowHighWaterSequence = null;
    }
  }

  bool _matchesCurrentBridge(Map<String, Object?> message) {
    final bridgeId = message['bridgeId'];
    if (bridgeId is String && bridgeId == _bridgeId) return true;
    _failTerminal(
      const MonkeyMuxAcpBridgeException(
        MonkeyMuxAcpBridgeErrorKind.invalidBridgeId,
        'The helper returned a frame for a different ACP bridge.',
      ),
    );
    return false;
  }

  void _sendAck(int sequence) {
    try {
      _sendWire({
        'version': monkeyMuxAcpBridgeProtocolVersion,
        'type': 'ack',
        'ack': sequence,
      });
    } on Object catch (error) {
      _handleChannelLoss(_generation, error);
    }
  }

  void _flushPendingInput() {
    if (!_connected || _channel == null || _closed || _terminalFailure) return;
    while (_pendingInputFrames.isNotEmpty && _connected) {
      final frame = _pendingInputFrames.removeFirst();
      try {
        _sendWire({
          'version': monkeyMuxAcpBridgeProtocolVersion,
          'type': 'input',
          'data': jsonDecode(utf8.decode(frame, allowMalformed: false)),
        });
      } on Object catch (error) {
        _pendingInputFrames.addFirst(frame);
        _handleChannelLoss(_generation, error);
        return;
      }
    }
  }

  void _sendWire(Map<String, Object?> message) {
    final channel = _channel;
    if (channel == null) {
      throw const MonkeyMuxAcpBridgeException(
        MonkeyMuxAcpBridgeErrorKind.sshChannel,
        'The SSH bridge channel is detached.',
      );
    }
    final bytes = utf8.encode('${jsonEncode(message)}\n');
    if (bytes.length > monkeyMuxAcpBridgeMaxFrameBytes) {
      throw const MonkeyMuxAcpBridgeException(
        MonkeyMuxAcpBridgeErrorKind.frameTooLarge,
        'The bridge frame exceeded the protocol limit.',
      );
    }
    channel.write(Uint8List.fromList(bytes));
  }

  void _handleChannelLoss(int generation, Object? error) {
    if (generation != _generation || _closed || _terminalFailure) return;
    _connected = false;
    _handshakeHighWaterSequence = null;
    _replayWindowRetainedFrom = null;
    _replayWindowHighWaterSequence = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    final channel = _channel;
    _channel = null;
    unawaited(_stdoutSubscription?.cancel());
    unawaited(_stderrSubscription?.cancel());
    _stdoutSubscription = null;
    _stderrSubscription = null;
    channel?.close();
    _scheduleReconnect(error);
  }

  void _scheduleReconnect(Object? error) {
    if (_closed || _terminalFailure || _reconnectTimer != null) return;
    if (_reconnectBackoff.isEmpty ||
        _reconnectAttempt >= _reconnectBackoff.length) {
      final kind =
          error is MonkeyMuxInstallException ||
              (error is MonkeyMuxAcpBridgeException &&
                  error.kind == MonkeyMuxAcpBridgeErrorKind.helperUnavailable)
          ? MonkeyMuxAcpBridgeErrorKind.helperUnavailable
          : MonkeyMuxAcpBridgeErrorKind.sshChannel;
      _failTerminal(
        MonkeyMuxAcpBridgeException(
          kind,
          kind == MonkeyMuxAcpBridgeErrorKind.helperUnavailable
              ? 'The MonkeyMux ACP helper is unavailable.'
              : 'The ACP bridge could not reconnect.',
        ),
      );
      return;
    }
    final delay = _reconnectBackoff[_reconnectAttempt];
    _reconnectAttempt += 1;
    _emitState(
      MonkeyMuxAcpTransportStatus.reconnecting,
      attempt: _reconnectAttempt,
    );
    _diagnostics.warning(
      'acp.transport',
      'reconnect_scheduled',
      fields: {
        'providerHash': _providerHash,
        'bridgeId': _bridgeId,
        'sequence': _lastDeliveredSequence,
        'attempt': _reconnectAttempt,
        'delayMs': delay.inMilliseconds,
        'errorType': error?.runtimeType ?? 'channelClosed',
      },
    );
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!_closed && !_terminalFailure) unawaited(_openChannel());
    });
  }

  void _failTerminal(
    MonkeyMuxAcpBridgeException error, {
    bool emitFailedState = true,
    int? exitCode,
  }) {
    if (_closed || _terminalFailure) return;
    _terminalFailure = true;
    _connected = false;
    _errors.add(error);
    if (emitFailedState) {
      _emitState(MonkeyMuxAcpTransportStatus.failed);
    }
    _diagnostics.error(
      'acp.transport',
      'terminal_failure',
      fields: {
        'providerHash': _providerHash,
        'bridgeId': _bridgeId,
        'sequence': _lastDeliveredSequence,
        'errorType': error.kind,
        'exitCode': ?exitCode,
      },
    );
    scheduleMicrotask(() => unawaited(_releaseResources(closeStreams: true)));
  }

  Future<void> _closeLocal() async {
    if (_closed) return;
    _closed = true;
    _connected = false;
    _emitState(MonkeyMuxAcpTransportStatus.closed);
    await _releaseResources(closeStreams: true);
  }

  Future<void> _releaseResources({required bool closeStreams}) async {
    final existing = _releaseFuture;
    if (existing != null) return existing;
    final release = _doReleaseResources(closeStreams: closeStreams);
    _releaseFuture = release;
    return release;
  }

  Future<void> _doReleaseResources({required bool closeStreams}) async {
    _generation += 1;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    final stdoutSubscription = _stdoutSubscription;
    final stderrSubscription = _stderrSubscription;
    _stdoutSubscription = null;
    _stderrSubscription = null;
    await stdoutSubscription?.cancel();
    await stderrSubscription?.cancel();
    final channel = _channel;
    _channel = null;
    channel?.close();
    _wireFrame.clear();
    _outgoingFrame.clear();
    _pendingInputFrames.clear();
    if (closeStreams) {
      if (!_incoming.isClosed) unawaited(_incoming.close());
      if (!_errors.isClosed) unawaited(_errors.close());
      if (!_states.isClosed) unawaited(_states.close());
    }
  }

  void _emitState(
    MonkeyMuxAcpTransportStatus status, {
    int attempt = 0,
    MonkeyMuxAcpProviderState? providerState,
    int? exitCode,
    int? retainedFrom,
  }) {
    if (_states.isClosed) return;
    _states.add(
      MonkeyMuxAcpTransportState(
        status: status,
        bridgeId: _bridgeId,
        lastDeliveredSequence: _lastDeliveredSequence,
        attempt: attempt,
        providerState: providerState,
        exitCode: exitCode,
        retainedFrom: retainedFrom,
      ),
    );
  }
}

String _buildHelperCommand(
  MonkeyMuxInstallation installation,
  List<String> arguments,
) {
  if (!installation.isWindows) {
    return [
      installation.executablePath,
      ...arguments,
    ].map(_posixShellQuote).join(' ');
  }
  const helperVariable = r'$__flAcpHelper';
  const argumentsVariable = r'$__flAcpArgs';
  const argumentsSplat = '@__flAcpArgs';
  final script = [
    r"$ErrorActionPreference='Stop';",
    '$helperVariable=${powerShellSingleQuote(installation.executablePath)};',
    '$argumentsVariable=@(',
    arguments.map(powerShellSingleQuote).join(','),
    ');',
    '& $helperVariable $argumentsSplat;',
    r'if($null -ne $LASTEXITCODE){exit $LASTEXITCODE}',
  ].join();
  return buildWindowsPowerShellCommand(script);
}

Map<String, Object?> _decodeSingleFrame(
  List<int> bytes, {
  required int maxBytes,
}) {
  if (bytes.length > maxBytes) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.frameTooLarge,
      'The bridge frame exceeded its limit.',
    );
  }
  late final String text;
  try {
    text = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidFrame,
      'The helper returned invalid UTF-8.',
    );
  }
  final lines = const LineSplitter()
      .convert(text)
      .where((line) => line.trim().isNotEmpty)
      .toList(growable: false);
  if (lines.length != 1) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidFrame,
      'The helper returned invalid NDJSON framing.',
    );
  }
  Object? decoded;
  try {
    decoded = jsonDecode(lines.single);
  } on FormatException {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidFrame,
      'The helper returned invalid JSON.',
    );
  }
  if (decoded is! Map) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidFrame,
      'The helper returned a non-object bridge frame.',
    );
  }
  final message = decoded.map((key, value) => MapEntry(key.toString(), value));
  if (message['version'] != monkeyMuxAcpBridgeProtocolVersion) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.unsupportedVersion,
      'The helper uses an unsupported ACP bridge protocol version.',
    );
  }
  return message;
}

MonkeyMuxAcpBridgeMetadata _parseBridgeMetadata(Object? value) {
  if (value is! Map) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidMetadata,
      'The helper returned invalid bridge metadata.',
    );
  }
  final map = value.map((key, item) => MapEntry(key.toString(), item));
  final id = _readBridgeId(map['id']);
  final provider = map['provider'];
  final providerId = _readOptionalMetadataString(map['providerId'], 128);
  final sessionId = _readOptionalMetadataString(map['sessionId'], 4096);
  final cwd = _readOptionalMetadataString(map['cwd'], 4096);
  final commandHash = map['commandHash'];
  final stateValue = map['state'];
  final clientCount = _readNonNegativeInt(map['clientCount']);
  final pendingCount = _readNonNegativeInt(map['pendingRequestCount']);
  final inFlightCount = _readNonNegativeInt(map['inFlightTurnCount']);
  final lastActivity = _readNonNegativeInt(map['lastActivityUnix']);
  final startedAt = _readNonNegativeInt(map['startedAtUnix']);
  final nextSequence = _readNonNegativeInt(map['nextSequence']);
  if (provider is! String ||
      provider.length > 128 ||
      commandHash is! String ||
      !_commandHashPattern.hasMatch(commandHash) ||
      stateValue is! String ||
      stateValue.length > 32 ||
      clientCount == null ||
      pendingCount == null ||
      inFlightCount == null ||
      lastActivity == null ||
      startedAt == null ||
      nextSequence == null) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidMetadata,
      'The helper returned invalid bridge metadata.',
    );
  }
  return MonkeyMuxAcpBridgeMetadata(
    id: id,
    providerId: providerId,
    sessionId: sessionId,
    cwd: cwd,
    provider: provider,
    commandHash: commandHash,
    state: _parseProviderState(stateValue),
    clientCount: clientCount,
    pendingRequestCount: pendingCount,
    inFlightTurnCount: inFlightCount,
    lastActivity: DateTime.fromMillisecondsSinceEpoch(
      lastActivity * 1000,
      isUtc: true,
    ),
    startedAt: DateTime.fromMillisecondsSinceEpoch(
      startedAt * 1000,
      isUtc: true,
    ),
    nextSequence: nextSequence,
  );
}

MonkeyMuxAcpProviderState _parseProviderState(Object? state) => switch (state) {
  'starting' => MonkeyMuxAcpProviderState.starting,
  'running' => MonkeyMuxAcpProviderState.running,
  'exited' => MonkeyMuxAcpProviderState.exited,
  'stopped' => MonkeyMuxAcpProviderState.stopped,
  'protocol_error' => MonkeyMuxAcpProviderState.protocolError,
  _ => MonkeyMuxAcpProviderState.unknown,
};

void _validateLaunch(String providerId, String providerLabel, String cwd) {
  if (providerId.trim().isEmpty ||
      providerLabel.trim().isEmpty ||
      providerLabel.length > 128 ||
      cwd.trim().isEmpty ||
      cwd.length > 4096 ||
      providerLabel.contains('\u0000') ||
      cwd.contains('\u0000')) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidLaunch,
      'The ACP provider launch configuration is invalid.',
    );
  }
}

void _validateBridgeId(String bridgeId) {
  if (!isValidMonkeyMuxAcpBridgeId(bridgeId)) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidBridgeId,
      'The ACP bridge identifier is invalid.',
    );
  }
}

String _readBridgeId(Object? value) {
  if (value is! String || !isValidMonkeyMuxAcpBridgeId(value)) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidBridgeId,
      'The helper returned an invalid ACP bridge identifier.',
    );
  }
  return value;
}

String? _readOptionalMetadataString(Object? value, int maxLength) {
  if (value == null || value == '') {
    return null;
  }
  if (value is! String ||
      value.length > maxLength ||
      value.contains('\u0000')) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidMetadata,
      'The helper returned invalid bridge metadata.',
    );
  }
  return value;
}

int? _readNonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;

void _requireType(Map<String, Object?> message, String expected) {
  if (message['type'] != expected) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidFrame,
      'The helper returned an unexpected bridge response.',
    );
  }
}

void _validateAcpInputFrame(List<int> frame) {
  if (frame.length > monkeyMuxAcpBridgeMaxFrameBytes) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.frameTooLarge,
      'The ACP input frame exceeded the bridge limit.',
    );
  }
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(frame, allowMalformed: false));
  } on FormatException {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidFrame,
      'ACP input must be valid UTF-8 JSON.',
    );
  }
  if (decoded is! Map) {
    throw const MonkeyMuxAcpBridgeException(
      MonkeyMuxAcpBridgeErrorKind.invalidFrame,
      'ACP input must be a JSON object.',
    );
  }
}

String _providerHash(String providerId) =>
    sha256.convert(utf8.encode(providerId)).toString().substring(0, 16);

String _posixShellQuote(String value) =>
    "'${value.replaceAll("'", "'\"'\"'")}'";

void _ignoreStreamError(Object _, StackTrace _) {}
