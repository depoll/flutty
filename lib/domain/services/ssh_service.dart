import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';

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
    this.jumpHost,
    this.keepAliveInterval = const Duration(seconds: 30),
    this.connectionTimeout = const Duration(seconds: 30),
  });

  /// Creates config from a Host entity.
  factory SshConnectionConfig.fromHost(
    Host host, {
    SshKey? key,
    SshConnectionConfig? jumpHostConfig,
  }) => SshConnectionConfig(
    hostname: host.hostname,
    port: host.port,
    username: host.username,
    password: host.password,
    privateKey: key?.privateKey,
    passphrase: key?.passphrase,
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
}

/// Service for managing SSH connections.
class SshService {
  /// Creates a new [SshService].
  SshService({this.hostRepository, this.keyRepository});

  /// Host repository for looking up hosts.
  final HostRepository? hostRepository;

  /// Key repository for looking up keys.
  final KeyRepository? keyRepository;

  final Map<int, SshSession> _sessions = {};
  int _nextConnectionId = 1;

  /// Get all active sessions.
  Map<int, SshSession> get sessions => Map.unmodifiable(_sessions);

  /// Connect to a host by ID.
  Future<SshConnectionResult> connectToHost(int hostId) async {
    if (hostRepository == null) {
      return const SshConnectionResult(
        success: false,
        error: 'Host repository not available',
      );
    }

    final host = await hostRepository!.getById(hostId);
    if (host == null) {
      return const SshConnectionResult(success: false, error: 'Host not found');
    }

    // Get SSH key if specified
    SshKey? key;
    if (host.keyId != null && keyRepository != null) {
      key = await keyRepository!.getById(host.keyId!);
    }

    // Get jump host config if specified
    SshConnectionConfig? jumpHostConfig;
    if (host.jumpHostId != null) {
      final jumpHost = await hostRepository!.getById(host.jumpHostId!);
      if (jumpHost != null) {
        SshKey? jumpKey;
        if (jumpHost.keyId != null && keyRepository != null) {
          jumpKey = await keyRepository!.getById(jumpHost.keyId!);
        }
        jumpHostConfig = SshConnectionConfig.fromHost(jumpHost, key: jumpKey);
      }
    }

    final config = SshConnectionConfig.fromHost(
      host,
      key: key,
      jumpHostConfig: jumpHostConfig,
    );

    final result = await connect(config);

    if (result.success && result.client != null) {
      final connectionId = _nextConnectionId++;
      _sessions[connectionId] = SshSession(
        connectionId: connectionId,
        hostId: hostId,
        client: result.client!,
        config: config,
      );

      // Update last connected timestamp
      await hostRepository!.updateLastConnected(hostId);
      return SshConnectionResult(
        success: true,
        client: result.client,
        connectionId: connectionId,
      );
    }

    return result;
  }

  /// Connect with a configuration.
  Future<SshConnectionResult> connect(SshConnectionConfig config) async {
    try {
      SSHSocket socket;

      // Handle jump host
      if (config.jumpHost != null) {
        final jumpResult = await connect(config.jumpHost!);
        if (!jumpResult.success || jumpResult.client == null) {
          return SshConnectionResult(
            success: false,
            error: 'Failed to connect to jump host: ${jumpResult.error}',
          );
        }

        // Create forwarded connection through jump host
        // SSHForwardChannel implements SSHSocket
        socket = await jumpResult.client!.forwardLocal(
          config.hostname,
          config.port,
        );
      } else {
        socket = await _connectWithKeepAlive(
          config.hostname,
          config.port,
          timeout: config.connectionTimeout,
        );
      }

      final client = SSHClient(
        socket,
        username: config.username,
        onPasswordRequest: config.password != null
            ? () => config.password!
            : null,
        identities: config.privateKey != null
            ? _parsePrivateKey(config.privateKey!, config.passphrase)
            : null,
        keepAliveInterval: config.keepAliveInterval,
      );

      // Wait for authentication to complete
      await client.authenticated;

      return SshConnectionResult(success: true, client: client);
    } on SSHAuthFailError catch (e) {
      return SshConnectionResult(
        success: false,
        error: 'Authentication failed: ${e.message}',
      );
    } on SocketException catch (e) {
      return SshConnectionResult(
        success: false,
        error: 'Connection failed: ${e.message}',
      );
    } on TimeoutException {
      return const SshConnectionResult(
        success: false,
        error: 'Connection timed out',
      );
    } on Exception catch (e) {
      return SshConnectionResult(success: false, error: 'Connection error: $e');
    }
  }

  /// Disconnect a session by connection ID.
  Future<void> disconnect(int connectionId) async {
    final session = _sessions.remove(connectionId);
    await session?.close();
  }

  /// Disconnect all sessions.
  Future<void> disconnectAll() async {
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

/// An active SSH session.
class SshSession {
  /// Creates a new [SshSession].
  SshSession({
    required this.connectionId,
    required this.hostId,
    required this.client,
    required this.config,
  }) : createdAt = DateTime.now();

  /// The connection ID for this active session.
  final int connectionId;

  /// The host ID this session is connected to.
  final int hostId;

  /// The SSH client.
  final SSHClient client;

  /// The connection configuration.
  final SshConnectionConfig config;

  /// When the session was created.
  final DateTime createdAt;

  SSHSession? _shell;
  StreamController<String>? _shellStdoutController;
  StreamController<String>? _shellStderrController;
  StreamController<void>? _shellDoneController;
  StreamSubscription<String>? _shellStdoutSubscription;
  StreamSubscription<String>? _shellStderrSubscription;
  StreamSubscription<void>? _shellDoneSubscription;

  /// Persistent terminal that survives screen rebuilds.
  Terminal? _terminal;

  /// The persistent terminal for this session. Created on first shell open.
  Terminal? get terminal => _terminal;

  /// Ensure a [Terminal] exists and is wired to the shell streams.
  Terminal getOrCreateTerminal({int maxLines = 10000}) {
    _terminal ??= Terminal(maxLines: maxLines);
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
    _shell ??= await client.shell(pty: pty ?? const SSHPtyConfig());
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
  Future<void> closeShell() async {
    await _shellStdoutSubscription?.cancel();
    await _shellStderrSubscription?.cancel();
    await _shellDoneSubscription?.cancel();
    _shellStdoutSubscription = null;
    _shellStderrSubscription = null;
    _shellDoneSubscription = null;
    await _shellStdoutController?.close();
    await _shellStderrController?.close();
    await _shellDoneController?.close();
    _shellStdoutController = null;
    _shellStderrController = null;
    _shellDoneController = null;
    _shell?.close();
    _shell = null;
    _terminal = null;
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
        .listen((data) {
          terminal.write(data);
          _shellStdoutController!.add(data);
        }, onError: _shellStdoutController!.addError);
    _shellStderrSubscription = shell.stderr
        .cast<List<int>>()
        .transform(utf8.decoder)
        .listen((data) {
          terminal.write(data);
          _shellStderrController!.add(data);
        }, onError: _shellStderrController!.addError);
    _shellDoneSubscription = shell.done.asStream().listen(
      (_) => _shellDoneController!.add(null),
      onError: _shellDoneController!.addError,
    );

    // Wire terminal keyboard output → shell stdin (persistent).
    terminal.onOutput = (data) {
      shell.write(utf8.encode(data));
    };
  }

  /// Execute a command.
  Future<SSHSession> execute(String command) => client.execute(command);

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
      final tunnel = _ActiveTunnel(
        serverSocket: serverSocket,
        localPort: serverSocket.port,
        remoteHost: remoteHost,
        remotePort: remotePort,
        isLocal: true,
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
          debugPrint('Port forward connection error: $e');
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
      debugPrint('Failed to start local forward: $e');
      return false;
    }
  }

  /// Stop a specific port forward tunnel.
  Future<void> stopForward(int portForwardId) async {
    final tunnel = _activeTunnels.remove(portForwardId);
    if (tunnel != null) {
      await tunnel.subscription?.cancel();
      await tunnel.serverSocket.close();
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
  _ActiveTunnel({
    required this.serverSocket,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.isLocal,
  });

  final ServerSocket serverSocket;
  final int localPort;
  final String remoteHost;
  final int remotePort;
  final bool isLocal;
  // Cancelled in SshSession.stopForward().
  // ignore: cancel_subscriptions
  StreamSubscription<Socket>? subscription;
}

/// Provider for [SshService].
final sshServiceProvider = Provider<SshService>(
  (ref) => SshService(
    hostRepository: ref.watch(hostRepositoryProvider),
    keyRepository: ref.watch(keyRepositoryProvider),
  ),
);

/// Provider for tracking active SSH sessions.
final activeSessionsProvider =
    NotifierProvider<ActiveSessionsNotifier, Map<int, SshConnectionState>>(
      ActiveSessionsNotifier.new,
    );

/// Notifier for active SSH sessions state.
class ActiveSessionsNotifier extends Notifier<Map<int, SshConnectionState>> {
  late final SshService _sshService;
  final Map<int, int> _connectionHostIds = {};

  @override
  Map<int, SshConnectionState> build() {
    _sshService = ref.watch(sshServiceProvider);
    _connectionHostIds.clear();
    return {};
  }

  /// Connect to a host.
  Future<SshConnectionResult> connect(
    int hostId, {
    bool forceNew = false,
  }) async {
    if (!forceNew) {
      final existingConnectionId = getPreferredConnectionForHost(hostId);
      if (existingConnectionId != null) {
        return SshConnectionResult(
          success: true,
          connectionId: existingConnectionId,
          reusedConnection: true,
        );
      }
    }

    final result = await _sshService.connectToHost(hostId);

    if (result.success && result.connectionId != null) {
      final connectionId = result.connectionId!;
      _connectionHostIds[connectionId] = hostId;
      state = {...state, connectionId: SshConnectionState.connected};
    }

    return result;
  }

  /// Disconnect from a connection.
  Future<void> disconnect(int connectionId) async {
    await _sshService.disconnect(connectionId);
    _connectionHostIds.remove(connectionId);
    final next = {...state}..remove(connectionId);
    state = next;
  }

  /// Disconnect all active sessions.
  Future<void> disconnectAll() async {
    await _sshService.disconnectAll();
    _connectionHostIds.clear();
    state = {};
  }

  /// Get the state of a connection.
  SshConnectionState getState(int connectionId) =>
      state[connectionId] ?? SshConnectionState.disconnected;

  /// Get a session.
  SshSession? getSession(int connectionId) =>
      _sshService.getSession(connectionId);

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
        ),
      );
    }
    connections.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return connections;
  }
}
