part of 'ssh_service.dart';

enum _WindowsShellKind { cmd, powershell, pwsh }

class _SshSessionRuntime {
  _SshSessionRuntime(this._session);

  final SshSession _session;

  static const _stdinCloseTimeout = Duration(milliseconds: 250);

  SSHSession? _shell;
  StreamController<String>? _shellStdoutController;
  StreamController<String>? _shellStderrController;
  StreamController<void>? _shellDoneController;
  StreamSubscription<String>? _shellStdoutSubscription;
  StreamSubscription<String>? _shellStderrSubscription;
  StreamSubscription<void>? _shellDoneSubscription;
  Timer? _previewRefreshTimer;
  Timer? _shellIoDiagnosticsTimer;
  Timer? _terminalOutputFlushTimer;
  Timer? _monkeyMuxReplayCoalesceTimer;
  Timer? _terminalParsePumpTimer;
  Duration _terminalOutputFlushInterval = _defaultTerminalOutputFlushInterval;
  SSHSession? _pendingShellOutputShell;
  Terminal? _pendingShellOutputTerminal;
  final _pendingShellOutputs =
      Queue<({String stderrData, String stdoutData, String terminalData})>();
  int _pendingTerminalWriteChars = 0;
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
  String _terminalInsertModePendingInput = '';
  int _terminalInsertModePendingScanOffset = 0;
  String _monkeyMuxReplayDetectionTail = '';
  DateTime? _monkeyMuxReplayCoalesceDeadline;
  String _terminalParseBacklog = '';
  int _terminalParseOffset = 0;
  // Wall-clock time of the last repaint notification emitted while draining the
  // parse backlog. Null when the backlog is idle, so the first slice of a new
  // burst repaints immediately; while a multi-frame drain is in progress,
  // repaints are throttled to _terminalParseDrainNotifyInterval so a heavy
  // switch replay does not schedule one image-heavy frame per parsed slice.
  int? _lastTerminalParseNotifyAtMs;
  bool _isCoalescingMonkeyMuxReplay = false;
  bool _terminalColorSchemeUpdatesMode = false;
  bool _terminalInsertMode = false;

  Terminal? _terminal;

  static const _defaultTerminalOutputFlushInterval = Duration(milliseconds: 8);
  static const _monkeyMuxReplayCoalesceQuietPeriod = Duration(milliseconds: 24);
  // The replay that follows a window switch is coalesced so it renders as one
  // batch instead of janky pieces. The quiet-period timer resets on every
  // chunk, and a large image/content replay arrives as a continuous stream of
  // sub-quiet-period chunks, so the debounce never settles until the whole
  // multi-MB replay finishes downloading — the window stays blank and the
  // switch appears to hang (this happens whether or not the window's agent is
  // active; the replay stream alone is enough). Cap the hold so the batch
  // always flushes promptly; the budgeted parse keeps the catch-up smooth and
  // any replay still streaming after the cap renders progressively.
  static const _monkeyMuxReplayCoalesceMaxHold = Duration(milliseconds: 64);
  static const _maxTerminalOutputFlushChars = 64 * 1024;
  // A window switch with lots of content/images replays hundreds of KB (or MB)
  // at once. Parsing it all synchronously — the adapt pass, the xterm parser,
  // and the control-query scan all walk the whole payload — blocks the UI
  // thread and hangs the app. So the parse pipeline runs on bounded slices and
  // stops once a frame-time budget is spent, resuming on the next event-loop
  // turn. This drains as fast as the device allows (more per frame on faster
  // builds) while keeping any single turn short enough to stay responsive.
  // Image decoding is already async, so it does not count against this budget.
  static const _maxTerminalParseSliceChars = 32 * 1024;
  // While a single escape sequence is still incomplete (e.g. a multi-megabyte
  // Kitty image APC), the held bytes aren't rendered until the terminator
  // arrives, and re-feeding them in 32KB slices makes `adapt` re-copy the
  // growing pending buffer each call (O(n^2)). Take much larger slices in that
  // state so the sequence is gathered in a few calls; the time budget still
  // yields between slices.
  static const _maxTerminalParseSequenceSliceChars = 256 * 1024;
  static const _terminalParseFrameBudget = Duration(milliseconds: 8);
  // While draining a multi-frame backlog (a large switch/reconnect replay),
  // repaint at most this often. The parser keeps advancing every event-loop
  // turn, but coalescing the repaints keeps the raster thread — which must
  // re-composite the image-heavy screen each frame — from being handed frames
  // faster than it can draw them (which queues frames and stalls the switch for
  // hundreds of ms). The final slice always repaints, so the settled screen is
  // never delayed by more than this interval.
  static const _terminalParseDrainNotifyInterval = Duration(milliseconds: 96);
  static const _monkeyMuxActiveWindowReplayMarker =
      '\x1b\\\x1b[?1000l\x1b[?1002l\x1b[?1003l';
  // SSH pty negotiation sets TERM but cannot advertise COLORTERM or terminal
  // app hints. POSIX remotes get a login-shell bootstrap; Windows remotes use
  // shell-specific prefixes because Windows OpenSSH can acknowledge env requests
  // while still leaving the variables absent from cmd.exe/PowerShell. Keep TERM
  // itself unchanged: xterm-kitty terminfo is often absent on remote hosts, while
  // TERM_PROGRAM/KITTY_WINDOW_ID are enough for image capable CLIs to choose
  // Kitty graphics sequences. FORCE_HYPERLINK=1 makes OSC 8 capable CLIs
  // (Copilot, gh, ...) emit hyperlinks even though their capability probes don't
  // recognize this TERM/TERM_PROGRAM combination; MonkeySSH renders and opens
  // OSC 8 links, so advertising support is safe.
  static const _terminalCapabilityEnvironment = {
    'COLORTERM': 'truecolor',
    'TERM_PROGRAM': 'kitty',
    'KITTY_WINDOW_ID': '1',
    'FORCE_HYPERLINK': '1',
  };
  static const _trueColorLoginShellCommand =
      r"""exec env COLORTERM=truecolor TERM_PROGRAM=kitty KITTY_WINDOW_ID=1 FORCE_HYPERLINK=1 /bin/sh -lc 'if [ -n "$SHELL" ]; then exec "$SHELL" -l; else exec /bin/sh; fi'""";
  static const _windowsShellDetectionTimeout = Duration(seconds: 2);
  static const _windowsShellDetectionCommand = r'''
$ErrorActionPreference='SilentlyContinue'
function __flNormalizeShellName([string]$value){
if(!$value){return ''}
$value=[System.IO.Path]::GetFileNameWithoutExtension($value).ToLowerInvariant()
while($value.StartsWith('-')){$value=$value.Substring(1)}
if($value -eq 'cmd' -or $value -eq 'powershell' -or $value -eq 'pwsh'){$value}else{''}
}
$__flDefault=''
try{$__flDefault=(Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction Stop).DefaultShell}catch{}
$__flResolved=__flNormalizeShellName $__flDefault
if(!$__flResolved){$__flResolved='cmd'}
[Console]::Out.Write($__flResolved)
''';

  /// UTF-8 decoder that tolerates malformed bytes by emitting U+FFFD instead
  /// of throwing a [FormatException]. The shell stream carries raw terminal
  /// bytes, including replay history from MonkeyMux that can be truncated at
  /// the byte cap mid-character, so a strict decoder would drop the entire
  /// chunk (and any redraw bytes inside it) when the chunk happens to start
  /// mid-sequence. See https://github.com/depollsoft/MonkeySSH/issues for
  /// the symptom where window switches lose composer borders until the next
  /// resize redraw.
  static const _shellStreamDecoder = Utf8Decoder(allowMalformed: true);

  SSHSession? get shell => _shell;

  bool get hasShell => _shell != null;

  Terminal? get terminal => _terminal;

  bool get terminalColorSchemeUpdatesMode => _terminalColorSchemeUpdatesMode;

  Stream<String> get shellStdoutStream =>
      _shellStdoutController?.stream ?? const Stream.empty();

  Stream<String> get shellStderrStream =>
      _shellStderrController?.stream ?? const Stream.empty();

  Stream<void> get shellDoneStream =>
      _shellDoneController?.stream ?? const Stream.empty();

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

  Terminal getOrCreateTerminal({int maxLines = 10000}) {
    _terminal ??= Terminal(maxLines: maxLines);
    _terminal!
      ..onTitleChange = _session._handleWindowTitleChange
      ..onIconChange = _session._handleIconNameChange;
    _session.terminalHyperlinkTracker.attach(_terminal!);
    _terminal!.onPrivateOSC = _session._handlePrivateOsc;
    _refreshTerminalPreview();
    return _terminal!;
  }

  void writeToShell(String data) {
    _shell?.write(utf8.encode(data));
  }

  Future<SSHSession> getShell({
    SSHPtyConfig? pty,
    bool forceNew = false,
    String? command,
  }) async {
    if (forceNew) {
      await closeShell();
    }
    if (_shell == null) {
      final commandKind = command == null
          ? 'interactive_shell'
          : _diagnosticSshCommandKind(command);
      DiagnosticsLogService.instance.info(
        'ssh.shell',
        'open_start',
        fields: {
          'connectionId': _session.connectionId,
          'hostId': _session.hostId,
          'requestedPty': pty != null,
          'hasCommand': command != null,
          'commandKind': commandKind,
        },
      );
      try {
        _shell = await _openShell(pty: pty, command: command);
        DiagnosticsLogService.instance.info(
          'ssh.shell',
          'open_success',
          fields: {
            'connectionId': _session.connectionId,
            'hasCommand': command != null,
            'commandKind': commandKind,
          },
        );
      } on Object catch (error) {
        DiagnosticsLogService.instance.error(
          'ssh.shell',
          'open_failed',
          fields: {
            'connectionId': _session.connectionId,
            'errorType': error.runtimeType,
            'hasCommand': command != null,
            'commandKind': commandKind,
          },
        );
        _session._reportConnectionHealthFailureIfClosed(
          error,
          operation: 'shell',
        );
        rethrow;
      }
    } else {
      DiagnosticsLogService.instance.debug(
        'ssh.shell',
        'reuse_existing',
        fields: {'connectionId': _session.connectionId},
      );
    }
    _ensureShellStreamPipes();
    return _shell!;
  }

  Future<SSHSession> _openShell({SSHPtyConfig? pty, String? command}) async {
    final ptyConfig = pty ?? const SSHPtyConfig();
    if (command != null) {
      if (_session.remoteIsWindows) {
        return _session.client.execute(
          _windowsCapabilityCommand(command),
          pty: ptyConfig,
        );
      }
      return _session.client.execute(command, pty: ptyConfig);
    }

    if (_session.remoteIsWindows) {
      return _openWindowsCapabilityShell(ptyConfig);
    }

    try {
      return await _session.client.execute(
        _trueColorLoginShellCommand,
        pty: ptyConfig,
      );
    } on SSHChannelRequestError {
      DiagnosticsLogService.instance.warning(
        'ssh.shell',
        'truecolor_bootstrap_rejected',
        fields: {
          'connectionId': _session.connectionId,
          'hostId': _session.hostId,
        },
      );
      return _session.client.shell(pty: ptyConfig);
    }
  }

  Future<SSHSession> _openWindowsCapabilityShell(SSHPtyConfig ptyConfig) async {
    final shellKind = await _detectWindowsShellKind();
    final command = _windowsCapabilityShellCommand(shellKind);
    try {
      final shell = await _session.client.execute(command, pty: ptyConfig);
      DiagnosticsLogService.instance.info(
        'ssh.shell',
        'windows_prefixed_shell',
        fields: {
          'connectionId': _session.connectionId,
          'hostId': _session.hostId,
          'shellKind': shellKind.name,
        },
      );
      return shell;
    } on SSHChannelRequestError {
      DiagnosticsLogService.instance.warning(
        'ssh.shell',
        'windows_prefixed_shell_rejected',
        fields: {
          'connectionId': _session.connectionId,
          'hostId': _session.hostId,
          'shellKind': shellKind.name,
        },
      );
      return _session.client.shell(pty: ptyConfig);
    }
  }

  Future<_WindowsShellKind> _detectWindowsShellKind() async {
    final command = buildWindowsPowerShellCommand(
      _windowsShellDetectionCommand,
    );
    SSHSession? detectionSession;
    try {
      detectionSession = await _session.client.execute(command);
      final output = await _shellStreamDecoder
          .bind(detectionSession.stdout)
          .join()
          .timeout(_windowsShellDetectionTimeout);
      return _parseWindowsShellKind(output);
    } on SSHChannelRequestError {
      DiagnosticsLogService.instance.warning(
        'ssh.shell',
        'windows_shell_detection_rejected',
        fields: {
          'connectionId': _session.connectionId,
          'hostId': _session.hostId,
        },
      );
      return _WindowsShellKind.cmd;
    } on TimeoutException {
      DiagnosticsLogService.instance.warning(
        'ssh.shell',
        'windows_shell_detection_timed_out',
        fields: {
          'connectionId': _session.connectionId,
          'hostId': _session.hostId,
        },
      );
      return _WindowsShellKind.cmd;
    } finally {
      detectionSession?.close();
    }
  }

  _WindowsShellKind _parseWindowsShellKind(String output) {
    final normalized = output.trim().toLowerCase();
    return switch (normalized) {
      'powershell' => _WindowsShellKind.powershell,
      'pwsh' => _WindowsShellKind.pwsh,
      _ => _WindowsShellKind.cmd,
    };
  }

  String _windowsCapabilityShellCommand(_WindowsShellKind shellKind) {
    switch (shellKind) {
      case _WindowsShellKind.cmd:
        return '${_windowsCmdCapabilityPrefix(closeAfterCommand: false)}"';
      case _WindowsShellKind.powershell:
        return _windowsPowerShellCapabilityShellCommand('powershell.exe');
      case _WindowsShellKind.pwsh:
        return _windowsPowerShellCapabilityShellCommand('pwsh.exe');
    }
  }

  String _windowsCapabilityCommand(String command) =>
      '${_windowsCmdCapabilityPrefix(closeAfterCommand: true)}&& $command"';

  String _windowsCmdCapabilityPrefix({required bool closeAfterCommand}) =>
      'cmd.exe /d /${closeAfterCommand ? 'c' : 'k'} '
      '"set COLORTERM=truecolor&& '
      'set TERM_PROGRAM=kitty&& '
      'set KITTY_WINDOW_ID=1&& '
      'set FORCE_HYPERLINK=1';

  String _windowsPowerShellCapabilityShellCommand(String executable) {
    final script = _terminalCapabilityEnvironment.entries
        .map(
          (entry) =>
              r'$env:'
              '${entry.key}=${powerShellSingleQuote(entry.value)}',
        )
        .join(';');
    return '$executable -NoLogo -NoExit '
        '-EncodedCommand ${encodePowerShellCommand(script)}';
  }

  /// Close only the interactive shell channel while keeping the SSH client.
  Future<void> closeShell({bool waitForStreams = true}) async {
    _flushPendingShellOutput(drainAll: true);
    _drainTerminalParseBacklogNow();
    _terminalParsePumpTimer?.cancel();
    _terminalParsePumpTimer = null;
    _flushShellIoDiagnostics();
    _shellIoDiagnosticsTimer?.cancel();
    _shellIoDiagnosticsTimer = null;
    DiagnosticsLogService.instance.info(
      'ssh.shell',
      'close_start',
      fields: {
        'connectionId': _session.connectionId,
        'hadShell': _shell != null,
      },
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

    final shell = _shell;
    if (shell != null) {
      try {
        await shell.stdin.close().timeout(_stdinCloseTimeout);
      } on TimeoutException {
        DiagnosticsLogService.instance.warning(
          'ssh.shell',
          'stdin_close_timed_out',
          fields: {'connectionId': _session.connectionId},
        );
      } on Object catch (error) {
        DiagnosticsLogService.instance.warning(
          'ssh.shell',
          'stdin_close_failed',
          fields: {
            'connectionId': _session.connectionId,
            'errorType': error.runtimeType,
          },
        );
      }
      _closeShellBestEffort(shell);
    }
    _shell = null;
    _session._resetShellRuntimeMetadata();
    _terminalWindowMetrics = null;
    _terminalWindowQueryPendingInput = '';
    _terminalTmuxPassthroughPendingInput = '';
    _terminalControlModeUpdatePendingInput = '';
    _terminalInsertModePendingInput = '';
    // Reset the paired scan offset with the pending input it indexes into.
    // The drain above can end mid-escape-sequence, leaving a non-zero offset;
    // clearing the input but not the offset would make the next shell's first
    // replay slice resume parsing at a stale position and corrupt it.
    _terminalInsertModePendingScanOffset = 0;
    _terminalColorSchemeUpdatesMode = false;
    _terminalInsertMode = false;
    _lastTerminalParseNotifyAtMs = null;
    _terminal = null;
    DiagnosticsLogService.instance.info(
      'ssh.shell',
      'close_complete',
      fields: {'connectionId': _session.connectionId},
    );
  }

  void _closeShellBestEffort(SSHSession shell) {
    void logFailure(Object error) {
      DiagnosticsLogService.instance.warning(
        'ssh.shell',
        'close_failed',
        fields: {
          'connectionId': _session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }

    runZonedGuarded(shell.close, (error, _) => logFailure(error));
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
        .transform(_shellStreamDecoder)
        .listen(
          (data) {
            _recordShellIo(stdoutChars: data.length);
            final terminalData = _unwrapTerminalTmuxPassthrough(data);
            if (identical(_shell, shell) &&
                (terminalData.isNotEmpty || data.isNotEmpty)) {
              _enqueueShellOutput(
                shell: shell,
                terminal: terminal,
                terminalData: terminalData,
                stdoutData: data,
              );
              if (_shouldFlushShellOutputImmediately(terminalData)) {
                _flushPendingShellOutput(drainAll: true);
              }
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            _flushPendingShellOutput(drainAll: true);
            DiagnosticsLogService.instance.error(
              'ssh.shell',
              'stdout_error',
              fields: {
                'connectionId': _session.connectionId,
                'errorType': error.runtimeType,
              },
            );
            _session._reportConnectionHealthFailureIfClosed(
              error,
              operation: 'shell_stdout',
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
        .transform(_shellStreamDecoder)
        .listen(
          (data) {
            _recordShellIo(stderrChars: data.length);
            if (identical(_shell, shell) && data.isNotEmpty) {
              _enqueueShellOutput(
                shell: shell,
                terminal: terminal,
                terminalData: data,
                stderrData: data,
              );
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            _flushPendingShellOutput(drainAll: true);
            DiagnosticsLogService.instance.error(
              'ssh.shell',
              'stderr_error',
              fields: {
                'connectionId': _session.connectionId,
                'errorType': error.runtimeType,
              },
            );
            _session._reportConnectionHealthFailureIfClosed(
              error,
              operation: 'shell_stderr',
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
        _flushPendingShellOutput(drainAll: true);
        DiagnosticsLogService.instance.info(
          'ssh.shell',
          'done',
          fields: {'connectionId': _session.connectionId},
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
            'connectionId': _session.connectionId,
            'errorType': error.runtimeType,
          },
        );
        _session._reportConnectionHealthFailureIfClosed(
          error,
          operation: 'shell_done',
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
        SshSession._shellIoDiagnosticsInterval,
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
        'connectionId': _session.connectionId,
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

  void _enqueueShellOutput({
    required SSHSession shell,
    required Terminal terminal,
    required String terminalData,
    String? stdoutData,
    String? stderrData,
  }) {
    if (!identical(_shell, shell)) {
      return;
    }

    final stdoutChunk = stdoutData ?? '';
    final stderrChunk = stderrData ?? '';
    if (terminalData.isEmpty && stdoutChunk.isEmpty && stderrChunk.isEmpty) {
      return;
    }
    _pendingShellOutputs.add((
      terminalData: terminalData,
      stdoutData: stdoutChunk,
      stderrData: stderrChunk,
    ));
    _pendingTerminalWriteChars += terminalData.length;
    _pendingShellOutputShell = shell;
    _pendingShellOutputTerminal = terminal;

    if (_trackMonkeyMuxActiveWindowReplay(terminalData) ||
        _isCoalescingMonkeyMuxReplay) {
      _scheduleMonkeyMuxReplayCoalesceFlush();
      return;
    }

    if (!(_terminalOutputFlushTimer?.isActive ?? false)) {
      _terminalOutputFlushTimer = Timer(
        _terminalOutputFlushInterval,
        _flushPendingShellOutput,
      );
    }
  }

  bool _trackMonkeyMuxActiveWindowReplay(String terminalData) {
    if (terminalData.isEmpty) {
      return false;
    }
    final combined = _monkeyMuxReplayDetectionTail + terminalData;
    final detected = combined.contains(_monkeyMuxActiveWindowReplayMarker);
    final partialMarkerLength = _activeWindowReplayMarkerPrefixSuffixLength(
      combined,
    );
    const tailLength = _monkeyMuxActiveWindowReplayMarker.length - 1;
    _monkeyMuxReplayDetectionTail = combined.length <= tailLength
        ? combined
        : combined.substring(combined.length - tailLength);
    if (detected || partialMarkerLength > 2) {
      _isCoalescingMonkeyMuxReplay = true;
    }
    return detected;
  }

  int _activeWindowReplayMarkerPrefixSuffixLength(String data) {
    final maxLength = math.min(
      data.length,
      _monkeyMuxActiveWindowReplayMarker.length - 1,
    );
    for (var length = maxLength; length > 0; length -= 1) {
      final suffix = data.substring(data.length - length);
      if (_monkeyMuxActiveWindowReplayMarker.startsWith(suffix)) {
        return length;
      }
    }
    return 0;
  }

  void _scheduleMonkeyMuxReplayCoalesceFlush() {
    _terminalOutputFlushTimer?.cancel();
    _terminalOutputFlushTimer = null;
    final now = DateTime.now();
    final deadline = _monkeyMuxReplayCoalesceDeadline ??= now.add(
      _monkeyMuxReplayCoalesceMaxHold,
    );
    final untilDeadline = deadline.difference(now);
    if (untilDeadline <= Duration.zero) {
      _flushCoalescedMonkeyMuxReplay();
      return;
    }
    // Debounce on the quiet period, but never hold past the deadline so a
    // continuously-printing window still renders without waiting for a pause.
    final delay = untilDeadline < _monkeyMuxReplayCoalesceQuietPeriod
        ? untilDeadline
        : _monkeyMuxReplayCoalesceQuietPeriod;
    _monkeyMuxReplayCoalesceTimer?.cancel();
    _monkeyMuxReplayCoalesceTimer = Timer(
      delay,
      _flushCoalescedMonkeyMuxReplay,
    );
  }

  void _flushCoalescedMonkeyMuxReplay() {
    _monkeyMuxReplayCoalesceTimer?.cancel();
    _monkeyMuxReplayCoalesceTimer = null;
    if (DiagnosticsLogService.instance.enabled) {
      final heldMs = _monkeyMuxReplayCoalesceDeadline == null
          ? 0
          : _monkeyMuxReplayCoalesceMaxHold.inMilliseconds -
                _monkeyMuxReplayCoalesceDeadline!
                    .difference(DateTime.now())
                    .inMilliseconds;
      DiagnosticsLogService.instance.debug(
        'terminal.replay',
        'coalesce_flush',
        fields: {
          'connectionId': _session.connectionId,
          'chunks': _pendingShellOutputs.length,
          'chars': _pendingTerminalWriteChars,
          'heldMs': heldMs,
        },
      );
    }
    _monkeyMuxReplayCoalesceDeadline = null;
    _isCoalescingMonkeyMuxReplay = false;
    _flushPendingShellOutput(drainAll: true);
  }

  bool _shouldFlushShellOutputImmediately(String terminalData) =>
      !_isCoalescingMonkeyMuxReplay &&
      (terminalData.contains('\x1b]') || terminalData.contains('\x1b[?'));

  void _flushPendingShellOutput({bool drainAll = false}) {
    _terminalOutputFlushTimer?.cancel();
    _terminalOutputFlushTimer = null;
    _monkeyMuxReplayCoalesceTimer?.cancel();
    _monkeyMuxReplayCoalesceTimer = null;
    _monkeyMuxReplayCoalesceDeadline = null;
    _isCoalescingMonkeyMuxReplay = false;

    final shell = _pendingShellOutputShell;
    final terminal = _pendingShellOutputTerminal;
    if (shell != null && !identical(_shell, shell)) {
      // Pending output belongs to a stale shell (e.g. gathered before a
      // reconnect swapped `_shell`): discard it, and the parse backlog, so old
      // bytes never render into the new shell.
      _clearPendingShellOutput();
      return;
    }
    if (shell == null || terminal == null) {
      // No raw output is queued to flush. Leave any in-flight parse backlog
      // intact for the pump/drain: it belongs to the current shell, and wiping
      // it here (as `_clearPendingShellOutput` does) would drop the tail of a
      // large replay that `closeShell` then expects `_drainTerminalParseBacklogNow`
      // to render.
      return;
    }

    final output = _drainPendingShellOutputs(drainAll: drainAll);
    if (output.terminalData.isNotEmpty) {
      _enqueueTerminalParse(terminal, output.terminalData);
    }

    if (output.stdoutData.isNotEmpty) {
      final stdoutController = _shellStdoutController;
      if (stdoutController != null && !stdoutController.isClosed) {
        stdoutController.add(output.stdoutData);
      }
    }

    if (output.stderrData.isNotEmpty) {
      final stderrController = _shellStderrController;
      if (stderrController != null && !stderrController.isClosed) {
        stderrController.add(output.stderrData);
      }
    }

    if (_pendingShellOutputs.isNotEmpty) {
      _terminalOutputFlushTimer = Timer(
        _terminalOutputFlushInterval,
        _flushPendingShellOutput,
      );
      return;
    }

    _pendingShellOutputShell = null;
    _pendingShellOutputTerminal = null;
  }

  @visibleForTesting
  Duration get debugTerminalOutputFlushInterval => _terminalOutputFlushInterval;

  @visibleForTesting
  set debugTerminalOutputFlushInterval(Duration value) =>
      _terminalOutputFlushInterval = value;

  @visibleForTesting
  void debugFlushPendingTerminalOutput() =>
      _flushPendingShellOutput(drainAll: true);

  /// Queues [data] for parsing and pumps as much as fits in a frame-time
  /// budget. A single large remote replay (e.g. switching to a Copilot window
  /// full of images) must not run the whole adapt/parse/control-query pipeline
  /// synchronously, which would block the UI thread. The remainder resumes on
  /// the next event-loop turn so the app stays responsive while draining as
  /// fast as the device can manage.
  void _enqueueTerminalParse(Terminal terminal, String data) {
    if (data.isEmpty) {
      return;
    }
    // Drop already-consumed prefix before appending so the backing string does
    // not grow without bound across successive flushes.
    if (_terminalParseOffset > 0) {
      _terminalParseBacklog = _terminalParseBacklog.substring(
        _terminalParseOffset,
      );
      _terminalParseOffset = 0;
    }
    _terminalParseBacklog += data;
    _pumpTerminalParse(terminal);
  }

  void _pumpTerminalParse(Terminal terminal) {
    _terminalParsePumpTimer?.cancel();
    _terminalParsePumpTimer = null;
    if (!identical(_terminal, terminal)) {
      _terminalParseBacklog = '';
      _terminalParseOffset = 0;
      return;
    }

    final diagnosticsEnabled = DiagnosticsLogService.instance.enabled;
    final startOffset = _terminalParseOffset;
    final stopwatch = Stopwatch()..start();
    var processedAny = false;
    var sliceCount = 0;
    var worstSliceMicros = 0;
    while (_terminalParseOffset < _terminalParseBacklog.length) {
      final sliceStartMicros = diagnosticsEnabled
          ? stopwatch.elapsedMicroseconds
          : 0;
      _processTerminalParseSlice(terminal, _takeTerminalParseSlice());
      processedAny = true;
      sliceCount += 1;
      if (diagnosticsEnabled) {
        final sliceMicros = stopwatch.elapsedMicroseconds - sliceStartMicros;
        if (sliceMicros > worstSliceMicros) {
          worstSliceMicros = sliceMicros;
        }
      }
      if (stopwatch.elapsed >= _terminalParseFrameBudget) {
        break;
      }
    }

    final remaining = _terminalParseBacklog.length - _terminalParseOffset;
    if (remaining > 0) {
      _scheduleTerminalParsePump(terminal);
    } else {
      _terminalParseBacklog = '';
      _terminalParseOffset = 0;
    }
    if (processedAny) {
      _notifyTerminalParseProgress(terminal, drained: remaining == 0);
      _scheduleTerminalPreviewRefresh();
      if (diagnosticsEnabled) {
        DiagnosticsLogService.instance.debug(
          'terminal.parse',
          'pump',
          fields: {
            'connectionId': _session.connectionId,
            'slices': sliceCount,
            'chars': _terminalParseOffset - startOffset,
            'durationMs': stopwatch.elapsedMilliseconds,
            'worstSliceMs': (worstSliceMicros / 1000).round(),
            'remainingChars': remaining,
          },
        );
      }
    }
  }

  /// Repaints the terminal view for the slices parsed in this pump, coalescing
  /// repaints while a large backlog is still draining.
  ///
  /// Slices are written with [Terminal.writeSilently] (no per-slice repaint), so
  /// this owns the repaint. When the backlog is [drained] the settled screen is
  /// shown immediately. While it is still draining, repaints are throttled to
  /// [_terminalParseDrainNotifyInterval] so a burst of parsed slices collapses
  /// to one image-heavy frame instead of overrunning the raster thread. The
  /// first slice after an idle backlog always repaints so incoming output is not
  /// held back for interactive use.
  void _notifyTerminalParseProgress(
    Terminal terminal, {
    required bool drained,
  }) {
    if (drained) {
      _lastTerminalParseNotifyAtMs = null;
      terminal.notifyListeners();
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final lastMs = _lastTerminalParseNotifyAtMs;
    if (lastMs != null &&
        nowMs - lastMs < _terminalParseDrainNotifyInterval.inMilliseconds) {
      return;
    }
    _lastTerminalParseNotifyAtMs = nowMs;
    terminal.notifyListeners();
  }

  String _takeTerminalParseSlice() {
    final start = _terminalParseOffset;
    // A larger slice while mid-sequence keeps gathering a long escape sequence
    // (image APC) in O(n) instead of O(n^2); otherwise a small slice keeps each
    // frame's parse/image work bounded.
    final sliceChars = _terminalInsertModePendingInput.isEmpty
        ? _maxTerminalParseSliceChars
        : _maxTerminalParseSequenceSliceChars;
    var end = math.min(start + sliceChars, _terminalParseBacklog.length);
    // Avoid cutting a surrogate pair; the parser tolerates split escape
    // sequences via rollback but a lone surrogate corrupts the code point.
    if (end < _terminalParseBacklog.length &&
        _isHighSurrogate(_terminalParseBacklog.codeUnitAt(end - 1))) {
      end -= 1;
    }
    if (end <= start) {
      end = _terminalParseBacklog.length;
    }
    _terminalParseOffset = end;
    return _terminalParseBacklog.substring(start, end);
  }

  void _processTerminalParseSlice(Terminal terminal, String slice) {
    final terminalOutput = adaptTerminalInsertModeOutputForXterm(
      input: slice,
      pendingInput: _terminalInsertModePendingInput,
      pendingScanOffset: _terminalInsertModePendingScanOffset,
      insertMode: _terminalInsertMode,
      terminalColumns: terminal.viewWidth,
      terminalRows: terminal.viewHeight,
      cursorColumn: terminal.buffer.cursorX,
      cursorRow: terminal.buffer.cursorY,
      marginTop: terminal.buffer.marginTop,
      marginBottom: terminal.buffer.marginBottom,
      originMode: terminal.originMode,
    );
    _terminalInsertModePendingInput = terminalOutput.pendingInput;
    _terminalInsertModePendingScanOffset = terminalOutput.pendingScanOffset;
    _terminalInsertMode = terminalOutput.insertMode;
    if (terminalOutput.output.isNotEmpty) {
      terminal.writeSilently(terminalOutput.output);
    }
    _respondToTerminalWindowControlQueries(slice, terminal);
  }

  void _scheduleTerminalParsePump(Terminal terminal) {
    if (_terminalParsePumpTimer?.isActive ?? false) {
      return;
    }
    // Resume on the next event-loop turn so the engine can render a frame
    // between budgets; the run still completes within a handful of frames.
    _terminalParsePumpTimer = Timer(Duration.zero, () {
      _terminalParsePumpTimer = null;
      _pumpTerminalParse(terminal);
    });
  }

  bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  ({String stderrData, String stdoutData, String terminalData})
  _drainPendingShellOutputs({required bool drainAll}) {
    if (_pendingShellOutputs.isEmpty) {
      return (terminalData: '', stdoutData: '', stderrData: '');
    }

    final terminalOutput = StringBuffer();
    final stdoutOutput = StringBuffer();
    final stderrOutput = StringBuffer();
    var remaining = drainAll
        ? _pendingTerminalWriteChars
        : _maxTerminalOutputFlushChars;
    while (_pendingShellOutputs.isNotEmpty) {
      final next = _pendingShellOutputs.first;
      final terminalLength = next.terminalData.length;
      if (!drainAll &&
          terminalOutput.isNotEmpty &&
          terminalLength > remaining) {
        break;
      }

      _pendingShellOutputs.removeFirst();
      _pendingTerminalWriteChars -= terminalLength;
      terminalOutput.write(next.terminalData);
      stdoutOutput.write(next.stdoutData);
      stderrOutput.write(next.stderrData);
      if (!drainAll) {
        remaining -= terminalLength;
        if (remaining <= 0 && terminalOutput.isNotEmpty) {
          break;
        }
      }
    }
    return (
      terminalData: terminalOutput.toString(),
      stdoutData: stdoutOutput.toString(),
      stderrData: stderrOutput.toString(),
    );
  }

  void _clearPendingShellOutput() {
    _pendingShellOutputs.clear();
    _pendingTerminalWriteChars = 0;
    _pendingShellOutputShell = null;
    _pendingShellOutputTerminal = null;
    _monkeyMuxReplayDetectionTail = '';
    _monkeyMuxReplayCoalesceDeadline = null;
    _isCoalescingMonkeyMuxReplay = false;
    // Discard the chunked parse backlog and its in-flight pump too. This path
    // runs when queued output is dropped because it belongs to a stale shell;
    // leaving the backlog (or partial-sequence parser state) would let old
    // bytes render into a reconnected shell's terminal.
    _terminalParsePumpTimer?.cancel();
    _terminalParsePumpTimer = null;
    _terminalParseBacklog = '';
    _terminalParseOffset = 0;
    _lastTerminalParseNotifyAtMs = null;
    _terminalInsertModePendingInput = '';
    _terminalInsertModePendingScanOffset = 0;
    _terminalInsertMode = false;
  }

  /// Drains any queued terminal parse backlog immediately, ignoring the frame
  /// budget. Used on shutdown so the final frames of replay are not stranded by
  /// the pump timer.
  void _drainTerminalParseBacklogNow() {
    _terminalParsePumpTimer?.cancel();
    _terminalParsePumpTimer = null;
    final terminal = _terminal;
    if (terminal == null) {
      _terminalParseBacklog = '';
      _terminalParseOffset = 0;
      return;
    }
    final hadBacklog = _terminalParseOffset < _terminalParseBacklog.length;
    while (_terminalParseOffset < _terminalParseBacklog.length) {
      _processTerminalParseSlice(terminal, _takeTerminalParseSlice());
    }
    _terminalParseBacklog = '';
    _terminalParseOffset = 0;
    if (hadBacklog) {
      // Slices are written silently, so repaint the drained result once.
      _lastTerminalParseNotifyAtMs = null;
      terminal.notifyListeners();
    }
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
      theme: _session.terminalTheme,
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
    _previewRefreshTimer = Timer(SshSession._previewRefreshInterval, () {
      _previewRefreshTimer = null;
      _refreshTerminalPreview();
    });
  }

  void _refreshTerminalPreview() {
    final nextPreview = _terminal == null
        ? null
        : SshSession.buildTerminalPreview(_terminal!);
    final nextPreviewSnapshot = _terminal == null
        ? null
        : SshSession.buildTerminalPreviewSnapshot(_terminal!);
    if (nextPreview == _session._terminalPreview &&
        nextPreviewSnapshot == _session._terminalPreviewSnapshot) {
      return;
    }
    _session._terminalPreview = nextPreview;
    _session._terminalPreviewSnapshot = nextPreviewSnapshot;
    DiagnosticsLogService.instance.debug(
      'ssh.preview',
      'changed',
      fields: {
        'connectionId': _session.connectionId,
        'hasPreview': nextPreview != null,
        'charCount': nextPreview?.length ?? 0,
      },
    );
    _session._notifyPreviewChanged();
  }
}
