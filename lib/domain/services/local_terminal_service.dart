import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/database/database.dart';
import '../models/host_kind.dart';

/// Resolves platform shell executables and spawns local PTY sessions.
class LocalTerminalService {
  /// Creates a local terminal service.
  const LocalTerminalService();

  /// Whether local PTY sessions are available in this runtime.
  bool get isSupported => isLocalTerminalSupported();

  /// Creates a local SSH-compatible client for [host].
  Future<LocalTerminalSshClient> createClient(Host host) async {
    if (!isSupported) {
      throw UnsupportedError(
        'Local terminals are not supported on this platform.',
      );
    }
    final shell = await resolveShellExecutable();
    final workingDirectory = await resolveWorkingDirectory();
    return LocalTerminalSshClient(
      host: host,
      executable: shell.executable,
      arguments: shell.arguments,
      workingDirectory: workingDirectory,
      environment: shell.environment,
      remoteVersion: shell.remoteVersion,
    );
  }

  /// Resolves the interactive shell to launch on this device.
  @visibleForTesting
  Future<LocalShellLaunch> resolveShellExecutable() async {
    if (Platform.isWindows) {
      return _resolveWindowsShell();
    }
    if (Platform.isAndroid) {
      return _resolveAndroidShell();
    }
    return _resolvePosixShell();
  }

  /// Resolves the initial working directory for local shells.
  @visibleForTesting
  Future<String?> resolveWorkingDirectory() async {
    if (Platform.isAndroid) {
      final docs = await getApplicationDocumentsDirectory();
      return docs.path;
    }
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    final trimmed = home?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
    return Directory.current.path;
  }

  LocalShellLaunch _resolveWindowsShell() {
    final comSpec = _nonEmpty(Platform.environment['ComSpec']);
    final candidates = <String>[
      ?comSpec,
      r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      r'C:\Program Files\PowerShell\7\pwsh.exe',
      'pwsh.exe',
      'powershell.exe',
      'cmd.exe',
    ];
    for (final candidate in candidates) {
      if (_looksExecutable(candidate)) {
        final isCmd = candidate.toLowerCase().endsWith('cmd.exe');
        return LocalShellLaunch(
          executable: candidate,
          arguments: isCmd ? const ['/K'] : const ['-NoLogo'],
          environment: _baseEnvironment(
            remoteVersion: 'SSH-2.0-MonkeySSH_Local_Windows',
          ),
        );
      }
    }
    return LocalShellLaunch(
      executable: 'cmd.exe',
      arguments: const ['/K'],
      environment: _baseEnvironment(
        remoteVersion: 'SSH-2.0-MonkeySSH_Local_Windows',
      ),
    );
  }

  LocalShellLaunch _resolveAndroidShell() {
    const candidates = <String>[
      '/system/bin/sh',
      '/system/xbin/sh',
      '/bin/sh',
      'sh',
    ];
    final executable = candidates.firstWhere(
      _looksExecutable,
      orElse: () => '/system/bin/sh',
    );
    final environment = _baseEnvironment(
      remoteVersion: 'SSH-2.0-MonkeySSH_Local_Android',
    );
    final home = _nonEmpty(Platform.environment['HOME']);
    if (home != null) {
      environment['HOME'] = home;
    }
    environment['PATH'] = _androidPath();
    return LocalShellLaunch(
      executable: executable,
      arguments: const [],
      environment: environment,
    );
  }

  LocalShellLaunch _resolvePosixShell() {
    final preferred = _nonEmpty(Platform.environment['SHELL']);
    final candidates = <String>[
      ?preferred,
      '/bin/zsh',
      '/usr/bin/zsh',
      '/bin/bash',
      '/usr/bin/bash',
      '/bin/sh',
      '/usr/bin/sh',
    ];
    final executable = candidates.firstWhere(
      _looksExecutable,
      orElse: () => preferred ?? '/bin/sh',
    );
    return LocalShellLaunch(
      executable: executable,
      arguments: _posixLoginArguments(executable),
      environment: _baseEnvironment(
        remoteVersion: Platform.isMacOS
            ? 'SSH-2.0-MonkeySSH_Local_macOS'
            : 'SSH-2.0-MonkeySSH_Local_Linux',
      ),
    );
  }

  Map<String, String> _baseEnvironment({required String remoteVersion}) => {
    'TERM': 'xterm-256color',
    'COLORTERM': 'truecolor',
    'TERM_PROGRAM': 'MonkeySSH',
    'LANG': Platform.environment['LANG'] ?? 'en_US.UTF-8',
    '_MONKEYSSH_REMOTE_VERSION': remoteVersion,
  };

  List<String> _posixLoginArguments(String executable) {
    final base = executable.split(Platform.pathSeparator).last.toLowerCase();
    if (base == 'zsh' || base == 'bash' || base == 'sh' || base == 'fish') {
      return const ['-l'];
    }
    return const [];
  }

  String _androidPath() {
    final existing = _nonEmpty(Platform.environment['PATH']);
    const defaults =
        '/system/bin:/system/xbin:/vendor/bin:/product/bin:/apex/com.android.runtime/bin';
    if (existing == null) {
      return defaults;
    }
    return '$existing:$defaults';
  }

  bool _looksExecutable(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    if (!trimmed.contains(Platform.pathSeparator) &&
        !trimmed.contains('/') &&
        !trimmed.contains(r'\')) {
      return true;
    }
    try {
      return File(trimmed).existsSync();
    } on Object {
      return false;
    }
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }
}

/// Resolved shell launch parameters for a local terminal.
@immutable
class LocalShellLaunch {
  /// Creates shell launch parameters.
  const LocalShellLaunch({
    required this.executable,
    required this.arguments,
    required this.environment,
  });

  /// Shell executable path or command name.
  final String executable;

  /// Arguments passed to [executable].
  final List<String> arguments;

  /// Extra environment variables for the PTY.
  final Map<String, String> environment;

  /// Fake SSH version string used for platform detection paths.
  String get remoteVersion =>
      environment['_MONKEYSSH_REMOTE_VERSION'] ??
      'SSH-2.0-MonkeySSH_Local_Terminal';
}

/// Local-device [SSHClient] backed by an interactive PTY shell.
class LocalTerminalSshClient implements SSHClient {
  /// Creates a local terminal client.
  LocalTerminalSshClient({
    required this.host,
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.environment,
    required this.remoteVersion,
  });

  /// Host row this client was created for.
  final Host host;

  /// Shell executable.
  final String executable;

  /// Shell arguments.
  final List<String> arguments;

  /// Initial working directory, if known.
  final String? workingDirectory;

  /// Extra environment for spawned PTYs.
  final Map<String, String> environment;

  @override
  final String remoteVersion;

  final _done = Completer<void>();
  bool _isClosed = false;

  /// Whether this client serves a local terminal host.
  bool get isLocalTerminal => true;

  @override
  bool get isClosed => _isClosed;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> get authenticated => Future<void>.value();

  @override
  String get username => host.username;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    _ensureOpen();
    return LocalTerminalSshSession.interactive(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: {...this.environment, ...?environment},
      pty: pty ?? const SSHPtyConfig(),
    );
  }

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    _ensureOpen();
    if (pty != null && _looksLikeLoginShellCommand(command)) {
      return shell(pty: pty, environment: environment);
    }
    return LocalTerminalSshSession.exec(
      command: command,
      workingDirectory: workingDirectory,
      environment: {...this.environment, ...?environment},
      shellExecutable: executable,
    );
  }

  @override
  Future<SftpClient> sftp() async {
    throw UnsupportedError('Local terminals do not support SFTP.');
  }

  @override
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) async {
    throw UnsupportedError('Local terminals do not support port forwarding.');
  }

  @override
  Future<SSHRemoteForward?> forwardRemote({
    String? host,
    int? port,
    SSHRemoteConnectionFilter? filter,
  }) async {
    throw UnsupportedError('Local terminals do not support port forwarding.');
  }

  @override
  Future<Uint8List> run(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async {
    final result = await _runProcess(command, environment: environment);
    final out = StringBuffer();
    if (stdout) {
      out.write(result.stdout);
    }
    if (stderr && result.stderr.toString().isNotEmpty) {
      if (out.isNotEmpty) {
        out.writeln();
      }
      out.write(result.stderr);
    }
    return Uint8List.fromList(utf8.encode(out.toString()));
  }

  @override
  Future<SSHRunResult> runWithResult(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async {
    final result = await _runProcess(command, environment: environment);
    final stdoutBytes = stdout
        ? Uint8List.fromList(utf8.encode('${result.stdout}'))
        : Uint8List(0);
    final stderrBytes = stderr
        ? Uint8List.fromList(utf8.encode('${result.stderr}'))
        : Uint8List(0);
    final combined = BytesBuilder(copy: false)
      ..add(stdoutBytes)
      ..add(stderrBytes);
    return SSHRunResult(
      output: combined.takeBytes(),
      stdout: stdoutBytes,
      stderr: stderrBytes,
      exitCode: result.exitCode,
      exitSignal: null,
    );
  }

  Future<ProcessResult> _runProcess(
    String command, {
    Map<String, String>? environment,
  }) {
    final launch = _commandLaunch(command);
    return Process.run(
      launch.executable,
      launch.arguments,
      workingDirectory: workingDirectory,
      environment: {...this.environment, ...?environment},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  ({String executable, List<String> arguments}) _commandLaunch(String command) {
    if (Platform.isWindows) {
      final lower = executable.toLowerCase();
      if (lower.endsWith('cmd.exe') || lower == 'cmd' || lower == 'cmd.exe') {
        return (executable: executable, arguments: ['/C', command]);
      }
      return (
        executable: executable,
        arguments: ['-NoLogo', '-Command', command],
      );
    }
    return (executable: executable, arguments: ['-c', command]);
  }

  @override
  void close() {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  void _ensureOpen() {
    if (_isClosed) {
      throw StateError('Local terminal client is closed');
    }
  }

  static bool _looksLikeLoginShellCommand(String command) =>
      command.contains('COLORTERM=truecolor') ||
      command.contains('TERM_PROGRAM=kitty') ||
      command.contains('TERM_PROGRAM=MonkeySSH') ||
      command.contains('/bin/sh -lc') ||
      command.contains('/bin/bash -lc') ||
      command.contains('/bin/zsh -lc');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Interactive or one-shot local shell session implementing [SSHSession].
class LocalTerminalSshSession implements SSHSession {
  LocalTerminalSshSession._()
    : _stdinController = StreamController<Uint8List>(),
      _stdoutController = StreamController<Uint8List>(),
      _stderrController = StreamController<Uint8List>() {
    _stdinSubscription = _stdinController.stream.listen(_handleStdin);
  }

  /// Starts an interactive local PTY shell.
  factory LocalTerminalSshSession.interactive({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    String? workingDirectory,
    SSHPtyConfig pty = const SSHPtyConfig(),
  }) {
    final rows = pty.height > 0 ? pty.height : 24;
    final cols = pty.width > 0 ? pty.width : 80;
    final started = Pty.start(
      executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      rows: rows,
      columns: cols,
    );
    return LocalTerminalSshSession._().._attachPty(started);
  }

  /// Runs a short-lived local command without a PTY.
  static Future<LocalTerminalSshSession> exec({
    required String command,
    required Map<String, String> environment,
    required String shellExecutable,
    String? workingDirectory,
  }) async {
    final args = Platform.isWindows
        ? _windowsCommandArgs(shellExecutable, command)
        : <String>['-c', command];
    final process = await Process.start(
      shellExecutable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    return LocalTerminalSshSession._().._attachProcess(process);
  }

  Pty? _pty;
  Process? _process;
  late final StreamSubscription<Uint8List> _stdinSubscription;
  StreamSubscription<List<int>>? _outputSubscription;
  StreamSubscription<List<int>>? _stderrSubscription;
  final StreamController<Uint8List> _stdinController;
  final StreamController<Uint8List> _stdoutController;
  final StreamController<Uint8List> _stderrController;
  final _done = Completer<void>();
  final _exitCompleter = Completer<int?>();
  bool _closed = false;
  int? _exitCode;

  @override
  int? get exitCode => _exitCode;

  @override
  SSHSessionExitSignal? get exitSignal => null;

  @override
  StreamSink<Uint8List> get stdin => _stdinController.sink;

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> flush() async {}

  @override
  void write(Uint8List data) {
    if (_closed) {
      return;
    }
    final pty = _pty;
    if (pty != null) {
      pty.write(data);
      return;
    }
    final process = _process;
    if (process != null) {
      process.stdin.add(data);
    }
  }

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {
    final pty = _pty;
    if (pty == null) {
      return;
    }
    final cols = width > 0 ? width : 80;
    final rows = height > 0 ? height : 24;
    pty.resize(rows, cols);
  }

  @override
  void close() {
    unawaited(_finish(exitCode: _exitCode));
  }

  @override
  Future<int?> waitForExit({Duration? timeout}) {
    final future = _exitCompleter.future;
    return timeout == null
        ? future
        : future.timeout(timeout, onTimeout: () => null);
  }

  @override
  void kill(SSHSignal signal) {
    final mapped = _mapSignal(signal);
    final pty = _pty;
    if (pty != null) {
      pty.kill(mapped);
      return;
    }
    final process = _process;
    if (process != null) {
      process.kill(mapped);
    }
  }

  void _handleStdin(Uint8List data) {
    write(data);
  }

  void _attachPty(Pty pty) {
    _pty = pty;
    _outputSubscription = pty.output.listen(
      (chunk) {
        if (!_stdoutController.isClosed) {
          _stdoutController.add(chunk);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_stdoutController.isClosed) {
          _stdoutController.addError(error, stackTrace);
        }
      },
      onDone: () {
        unawaited(_finishFromPty());
      },
    );
    unawaited(
      pty.exitCode.then((code) {
        unawaited(_finish(exitCode: code));
      }),
    );
  }

  void _attachProcess(Process process) {
    _process = process;
    _outputSubscription = process.stdout.listen(
      (chunk) {
        if (!_stdoutController.isClosed) {
          _stdoutController.add(Uint8List.fromList(chunk));
        }
      },
      onDone: () {
        unawaited(_finishFromProcess());
      },
    );
    _stderrSubscription = process.stderr.listen((chunk) {
      if (!_stderrController.isClosed) {
        _stderrController.add(Uint8List.fromList(chunk));
      }
    });
    unawaited(
      process.exitCode.then((code) {
        unawaited(_finish(exitCode: code));
      }),
    );
  }

  Future<void> _finishFromPty() async {
    final pty = _pty;
    if (pty == null) {
      await _finish(exitCode: _exitCode ?? 0);
      return;
    }
    final code = await pty.exitCode;
    await _finish(exitCode: code);
  }

  Future<void> _finishFromProcess() async {
    final process = _process;
    if (process == null) {
      await _finish(exitCode: _exitCode ?? 0);
      return;
    }
    final code = await process.exitCode;
    await _finish(exitCode: code);
  }

  Future<void> _finish({required int? exitCode}) async {
    if (_closed) {
      return;
    }
    _closed = true;
    _exitCode = exitCode;
    await _stdinSubscription.cancel();
    await _outputSubscription?.cancel();
    await _stderrSubscription?.cancel();
    final pty = _pty;
    if (pty != null) {
      try {
        pty.kill();
      } on Object {
        // Best-effort.
      }
    }
    final process = _process;
    if (process != null) {
      try {
        process.kill();
      } on Object {
        // Best-effort.
      }
    }
    if (!_stdinController.isClosed) {
      await _stdinController.close();
    }
    if (!_stdoutController.isClosed) {
      await _stdoutController.close();
    }
    if (!_stderrController.isClosed) {
      await _stderrController.close();
    }
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(exitCode);
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  ProcessSignal _mapSignal(SSHSignal signal) => switch (signal) {
    SSHSignal.KILL => ProcessSignal.sigkill,
    SSHSignal.INT => ProcessSignal.sigint,
    SSHSignal.HUP => ProcessSignal.sighup,
    SSHSignal.QUIT => ProcessSignal.sigquit,
    SSHSignal.USR1 => ProcessSignal.sigusr1,
    SSHSignal.USR2 => ProcessSignal.sigusr2,
    _ => ProcessSignal.sigterm,
  };

  static List<String> _windowsCommandArgs(String executable, String command) {
    final lower = executable.toLowerCase();
    if (lower.endsWith('cmd.exe') || lower == 'cmd' || lower == 'cmd.exe') {
      return ['/C', command];
    }
    return ['-NoLogo', '-Command', command];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
