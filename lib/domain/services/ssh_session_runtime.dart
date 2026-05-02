part of 'ssh_service.dart';

class _SshSessionRuntime {
  _SshSessionRuntime(this._session);

  final SshSession _session;

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
  bool _terminalColorSchemeUpdatesMode = false;

  Terminal? _terminal;

  static const _terminalOutputFlushInterval = Duration(milliseconds: 16);
  static const _maxTerminalOutputFlushChars = 64 * 1024;

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
  }) async {
    if (forceNew) {
      await closeShell();
    }
    if (_shell == null) {
      DiagnosticsLogService.instance.info(
        'ssh.shell',
        'open_start',
        fields: {
          'connectionId': _session.connectionId,
          'hostId': _session.hostId,
          'requestedPty': pty != null,
        },
      );
      try {
        _shell = await _session.client.shell(pty: pty ?? const SSHPtyConfig());
        DiagnosticsLogService.instance.info(
          'ssh.shell',
          'open_success',
          fields: {'connectionId': _session.connectionId},
        );
      } on Object catch (error) {
        DiagnosticsLogService.instance.error(
          'ssh.shell',
          'open_failed',
          fields: {
            'connectionId': _session.connectionId,
            'errorType': error.runtimeType,
          },
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

  /// Close only the interactive shell channel while keeping the SSH client.
  Future<void> closeShell({bool waitForStreams = true}) async {
    _flushPendingShellOutput(drainAll: true);
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

    _shell?.close();
    _shell = null;
    _session._resetShellRuntimeMetadata();
    _terminalWindowMetrics = null;
    _terminalWindowQueryPendingInput = '';
    _terminalTmuxPassthroughPendingInput = '';
    _terminalControlModeUpdatePendingInput = '';
    _terminalColorSchemeUpdatesMode = false;
    _terminal = null;
    DiagnosticsLogService.instance.info(
      'ssh.shell',
      'close_complete',
      fields: {'connectionId': _session.connectionId},
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
            if (identical(_shell, shell) &&
                (terminalData.isNotEmpty || data.isNotEmpty)) {
              _enqueueShellOutput(
                shell: shell,
                terminal: terminal,
                terminalData: terminalData,
                stdoutData: data,
              );
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

    if (!(_terminalOutputFlushTimer?.isActive ?? false)) {
      _terminalOutputFlushTimer = Timer(
        _terminalOutputFlushInterval,
        _flushPendingShellOutput,
      );
    }
  }

  void _flushPendingShellOutput({bool drainAll = false}) {
    _terminalOutputFlushTimer?.cancel();
    _terminalOutputFlushTimer = null;

    final shell = _pendingShellOutputShell;
    final terminal = _pendingShellOutputTerminal;
    if (shell == null || terminal == null || !identical(_shell, shell)) {
      _clearPendingShellOutput();
      return;
    }

    final output = _drainPendingShellOutputs(drainAll: drainAll);
    if (output.terminalData.isNotEmpty) {
      terminal.write(output.terminalData);
      _respondToTerminalWindowControlQueries(output.terminalData, terminal);
      _scheduleTerminalPreviewRefresh();
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
    if (nextPreview == _session._terminalPreview) {
      return;
    }
    _session._terminalPreview = nextPreview;
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
