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
  bool _terminalOutputFlushTimerIsFallback = false;
  SSHSession? _pendingShellOutputShell;
  Terminal? _pendingShellOutputTerminal;
  final _pendingShellOutputs =
      Queue<({String stderrData, String stdoutData, String terminalData})>();
  int _pendingTerminalWriteChars = 0;
  String _pendingTerminalQueryScan = '';
  int _shellStdoutChunkCount = 0;
  int _shellStdoutCharCount = 0;
  int _shellStderrChunkCount = 0;
  int _shellStderrCharCount = 0;
  int _shellStdinWriteCount = 0;
  int _shellStdinCharCount = 0;
  TerminalWindowMetrics? _terminalWindowMetrics;
  String _terminalWindowQueryPendingInput = '';
  String _terminalThemeOscQueryPendingInput = '';
  String _terminalTmuxPassthroughPendingInput = '';
  String _terminalControlModeUpdatePendingInput = '';
  String _terminalSynchronizedOutputPendingInput = '';
  StringBuffer? _terminalSynchronizedOutputBuffer;
  StringBuffer? _terminalSynchronizedStdoutBuffer;
  StringBuffer? _terminalSynchronizedStderrBuffer;
  bool _terminalColorSchemeUpdatesMode = false;
  bool _terminalSynchronizedOutputMode = false;
  bool _terminalGraphemeClusterMode = false;

  Terminal? _terminal;

  static const _terminalOutputFlushInterval = Duration(milliseconds: 8);
  static const _terminalSynchronizedOutputFallbackInterval = Duration(
    milliseconds: 250,
  );
  static const _maxTerminalOutputFlushChars = 64 * 1024;
  static const _maxTerminalSynchronizedOutputChars = 64 * 1024;
  static const _terminalSynchronizedOutputBegin = '\x1b[?2026h';
  static const _terminalSynchronizedOutputEnd = '\x1b[?2026l';

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

  void sendTerminalThemeModeReport({String reason = 'unspecified'}) {
    final shell = _shell;
    final theme = _session.terminalTheme;
    if (shell == null || theme == null) {
      DiagnosticsLogService.instance.debug(
        'terminal.theme',
        'mode_report_skipped',
        fields: {
          'reason': reason,
          'connectionId': _session.connectionId,
          'hasShell': shell != null,
          'hasTheme': theme != null,
        },
      );
      return;
    }

    final report = buildTerminalThemeModeReport(isDark: theme.isDark);
    shell.write(utf8.encode(report));
    DiagnosticsLogService.instance.debug(
      'terminal.theme',
      'mode_report_sent',
      fields: {
        'reason': reason,
        'connectionId': _session.connectionId,
        'themeId': theme.id,
        'isDark': theme.isDark,
        'bytes': report.length,
      },
    );
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
        _shell = command == null
            ? await _session.client.shell(pty: pty ?? const SSHPtyConfig())
            : await _session.client.execute(
                command,
                pty: pty ?? const SSHPtyConfig(),
              );
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
    _terminalThemeOscQueryPendingInput = '';
    _terminalTmuxPassthroughPendingInput = '';
    _terminalControlModeUpdatePendingInput = '';
    _terminalSynchronizedOutputPendingInput = '';
    _terminalSynchronizedOutputBuffer = null;
    _terminalSynchronizedStdoutBuffer = null;
    _terminalSynchronizedStderrBuffer = null;
    _terminalColorSchemeUpdatesMode = false;
    _terminalSynchronizedOutputMode = false;
    _terminalGraphemeClusterMode = false;
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
              if (_shouldFlushShellOutputImmediately()) {
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
    _appendPendingTerminalQueryScan(terminalData);
    _pendingShellOutputShell = shell;
    _pendingShellOutputTerminal = terminal;

    if (_terminalOutputFlushTimerIsFallback &&
        (_terminalOutputFlushTimer?.isActive ?? false)) {
      _terminalOutputFlushTimer?.cancel();
      _terminalOutputFlushTimerIsFallback = false;
    }
    if (!(_terminalOutputFlushTimer?.isActive ?? false)) {
      _terminalOutputFlushTimer = Timer(
        _terminalOutputFlushInterval,
        _flushPendingShellOutput,
      );
    }
  }

  bool _shouldFlushShellOutputImmediately() {
    if (_pendingShellOutputs.isEmpty) {
      return false;
    }
    final queryScan = _pendingTerminalQueryScan;
    return _containsImmediateTerminalResponseQuery(queryScan) ||
        (_terminalThemeOscQueryPendingInput.isNotEmpty &&
            _containsImmediateTerminalResponseQuery(
              _terminalThemeOscQueryPendingInput + queryScan,
            ));
  }

  void _appendPendingTerminalQueryScan(String terminalData) {
    if (terminalData.isEmpty) {
      return;
    }
    final combined = _pendingTerminalQueryScan + terminalData;
    if (combined.length <= _terminalControlQueryPendingLimit) {
      _pendingTerminalQueryScan = combined;
      return;
    }
    _pendingTerminalQueryScan = combined.substring(
      combined.length - _terminalControlQueryPendingLimit,
    );
  }

  void _rebuildPendingTerminalQueryScan() {
    _pendingTerminalQueryScan = '';
    for (final output in _pendingShellOutputs) {
      _appendPendingTerminalQueryScan(output.terminalData);
    }
  }

  void _flushPendingShellOutput({bool drainAll = false}) {
    _terminalOutputFlushTimer?.cancel();
    _terminalOutputFlushTimer = null;
    _terminalOutputFlushTimerIsFallback = false;

    final shell = _pendingShellOutputShell;
    final terminal = _pendingShellOutputTerminal;
    if (shell == null || terminal == null || !identical(_shell, shell)) {
      _clearPendingShellOutput();
      return;
    }

    final output = _drainPendingShellOutputs(drainAll: drainAll);
    var terminalData = output.terminalData;
    var stdoutData = output.stdoutData;
    var stderrData = output.stderrData;
    if (terminalData.isNotEmpty || _hasPendingSynchronizedTerminalOutput) {
      final themeOscResult = _consumeTerminalThemeOscQueries(
        input: terminalData,
        pendingInput: _terminalThemeOscQueryPendingInput,
        theme: _session.terminalTheme,
      );
      _terminalThemeOscQueryPendingInput = themeOscResult.pendingInput;
      final themeOscResponse = themeOscResult.response;
      if (themeOscResponse != null) {
        _shell?.write(utf8.encode(themeOscResponse));
      }

      final synchronizedOutput = _coalesceSynchronizedTerminalOutput(
        terminalData: themeOscResult.terminalInput,
        stdoutData: stdoutData,
        stderrData: stderrData,
        drainAll: drainAll,
      );
      terminalData = synchronizedOutput.terminalData;
      stdoutData = synchronizedOutput.stdoutData;
      stderrData = synchronizedOutput.stderrData;
    }

    if (terminalData.isNotEmpty) {
      terminal.write(terminalData);
      _respondToTerminalWindowControlQueries(terminalData, terminal);
      _scheduleTerminalPreviewRefresh();
    }

    if (stdoutData.isNotEmpty) {
      final stdoutController = _shellStdoutController;
      if (stdoutController != null && !stdoutController.isClosed) {
        stdoutController.add(stdoutData);
      }
    }

    if (stderrData.isNotEmpty) {
      final stderrController = _shellStderrController;
      if (stderrController != null && !stderrController.isClosed) {
        stderrController.add(stderrData);
      }
    }

    _scheduleNextShellOutputFlushIfNeeded();
  }

  void _scheduleNextShellOutputFlushIfNeeded() {
    if (_pendingShellOutputs.isNotEmpty) {
      _terminalOutputFlushTimer = Timer(
        _terminalOutputFlushInterval,
        _flushPendingShellOutput,
      );
      _terminalOutputFlushTimerIsFallback = false;
      return;
    }

    if (_hasPendingSynchronizedTerminalOutput) {
      _terminalOutputFlushTimer = Timer(
        _terminalSynchronizedOutputFallbackInterval,
        () => _flushPendingShellOutput(drainAll: true),
      );
      _terminalOutputFlushTimerIsFallback = true;
      return;
    }

    _pendingShellOutputShell = null;
    _pendingShellOutputTerminal = null;
  }

  bool get _hasPendingSynchronizedTerminalOutput =>
      _hasPendingSynchronizedTerminalFrame ||
      _terminalSynchronizedStdoutBuffer != null ||
      _terminalSynchronizedStderrBuffer != null;

  bool get _hasPendingSynchronizedTerminalFrame =>
      _terminalSynchronizedOutputBuffer != null ||
      _terminalSynchronizedOutputPendingInput.isNotEmpty;

  ({String stderrData, String stdoutData, String terminalData})
  _coalesceSynchronizedTerminalOutput({
    required String terminalData,
    required String stdoutData,
    required String stderrData,
    required bool drainAll,
  }) {
    final hadPendingSynchronizedOutput = _hasPendingSynchronizedTerminalOutput;
    final terminalOutput = StringBuffer();
    final scanInput = _terminalSynchronizedOutputPendingInput + terminalData;
    _terminalSynchronizedOutputPendingInput = '';
    var cursor = 0;

    while (cursor < scanInput.length) {
      final activeBuffer = _terminalSynchronizedOutputBuffer;
      if (activeBuffer == null) {
        final beginIndex = scanInput.indexOf(
          _terminalSynchronizedOutputBegin,
          cursor,
        );
        if (beginIndex == -1) {
          final pendingSuffix = _synchronizedOutputPendingBeginSuffix(
            scanInput.substring(cursor),
          );
          final emitEnd = scanInput.length - pendingSuffix.length;
          if (emitEnd > cursor) {
            terminalOutput.write(scanInput.substring(cursor, emitEnd));
          }
          _terminalSynchronizedOutputPendingInput = pendingSuffix;
          break;
        }
        if (beginIndex > cursor) {
          terminalOutput.write(scanInput.substring(cursor, beginIndex));
        }
        _terminalSynchronizedOutputBuffer = StringBuffer(
          _terminalSynchronizedOutputBegin,
        );
        cursor = beginIndex + _terminalSynchronizedOutputBegin.length;
        continue;
      }

      final endIndex = scanInput.indexOf(
        _terminalSynchronizedOutputEnd,
        cursor,
      );
      if (endIndex == -1) {
        final pendingSuffix = _synchronizedOutputPendingEndSuffix(
          scanInput.substring(cursor),
        );
        final bufferEnd = scanInput.length - pendingSuffix.length;
        if (bufferEnd > cursor) {
          activeBuffer.write(scanInput.substring(cursor, bufferEnd));
          if (_pendingSynchronizedOutputChars >
              _maxTerminalSynchronizedOutputChars) {
            _terminalSynchronizedOutputPendingInput = pendingSuffix;
            _drainPendingSynchronizedTerminalFrame(terminalOutput);
            break;
          }
        }
        _terminalSynchronizedOutputPendingInput = pendingSuffix;
        break;
      }
      activeBuffer.write(
        scanInput.substring(
          cursor,
          endIndex + _terminalSynchronizedOutputEnd.length,
        ),
      );
      terminalOutput.write(activeBuffer.toString());
      _terminalSynchronizedOutputBuffer = null;
      cursor = endIndex + _terminalSynchronizedOutputEnd.length;
    }

    if (drainAll && _hasPendingSynchronizedTerminalFrame) {
      _drainPendingSynchronizedTerminalFrame(terminalOutput);
    }

    final shouldBufferStreamData =
        hadPendingSynchronizedOutput ||
        _hasPendingSynchronizedTerminalFrame ||
        scanInput.contains(_terminalSynchronizedOutputBegin);
    if (!shouldBufferStreamData) {
      return (
        terminalData: terminalOutput.toString(),
        stdoutData: stdoutData,
        stderrData: stderrData,
      );
    }

    if (stdoutData.isNotEmpty) {
      (_terminalSynchronizedStdoutBuffer ??= StringBuffer()).write(stdoutData);
    }
    if (stderrData.isNotEmpty) {
      (_terminalSynchronizedStderrBuffer ??= StringBuffer()).write(stderrData);
    }

    if (_hasPendingSynchronizedTerminalFrame &&
        _pendingSynchronizedOutputChars > _maxTerminalSynchronizedOutputChars) {
      _drainPendingSynchronizedTerminalFrame(terminalOutput);
    }

    if (_hasPendingSynchronizedTerminalFrame) {
      return (
        terminalData: terminalOutput.toString(),
        stdoutData: '',
        stderrData: '',
      );
    }

    final synchronizedStdout =
        _terminalSynchronizedStdoutBuffer?.toString() ?? '';
    final synchronizedStderr =
        _terminalSynchronizedStderrBuffer?.toString() ?? '';
    _terminalSynchronizedStdoutBuffer = null;
    _terminalSynchronizedStderrBuffer = null;
    return (
      terminalData: terminalOutput.toString(),
      stdoutData: synchronizedStdout,
      stderrData: synchronizedStderr,
    );
  }

  int get _pendingSynchronizedOutputChars =>
      (_terminalSynchronizedOutputBuffer?.length ?? 0) +
      _terminalSynchronizedOutputPendingInput.length +
      (_terminalSynchronizedStdoutBuffer?.length ?? 0) +
      (_terminalSynchronizedStderrBuffer?.length ?? 0);

  void _drainPendingSynchronizedTerminalFrame(StringBuffer terminalOutput) {
    if (_terminalSynchronizedOutputPendingInput.isNotEmpty) {
      final pendingInput = _terminalSynchronizedOutputPendingInput;
      _terminalSynchronizedOutputPendingInput = '';
      if (_terminalSynchronizedOutputBuffer == null) {
        terminalOutput.write(pendingInput);
      } else {
        _terminalSynchronizedOutputBuffer!.write(pendingInput);
      }
    }
    final activeBuffer = _terminalSynchronizedOutputBuffer;
    if (activeBuffer != null) {
      terminalOutput.write(activeBuffer.toString());
      _terminalSynchronizedOutputBuffer = null;
    }
  }

  static String _synchronizedOutputPendingBeginSuffix(String input) =>
      _terminalPendingSequenceSuffix(input, _terminalSynchronizedOutputBegin);

  static String _synchronizedOutputPendingEndSuffix(String input) =>
      _terminalPendingSequenceSuffix(input, _terminalSynchronizedOutputEnd);

  static String _terminalPendingSequenceSuffix(String input, String sequence) {
    final maxSuffixLength = math.min(input.length, sequence.length - 1);
    for (var length = maxSuffixLength; length > 0; length -= 1) {
      final suffix = input.substring(input.length - length);
      if (sequence.startsWith(suffix)) {
        return suffix;
      }
    }
    return '';
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
    _rebuildPendingTerminalQueryScan();
    return (
      terminalData: terminalOutput.toString(),
      stdoutData: stdoutOutput.toString(),
      stderrData: stderrOutput.toString(),
    );
  }

  void _clearPendingShellOutput() {
    _pendingShellOutputs.clear();
    _pendingTerminalWriteChars = 0;
    _pendingTerminalQueryScan = '';
    _pendingShellOutputShell = null;
    _pendingShellOutputTerminal = null;
    _terminalOutputFlushTimerIsFallback = false;
    _terminalSynchronizedOutputPendingInput = '';
    _terminalSynchronizedOutputBuffer = null;
    _terminalSynchronizedStdoutBuffer = null;
    _terminalSynchronizedStderrBuffer = null;
  }

  void _respondToTerminalWindowControlQueries(String data, Terminal terminal) {
    final modeUpdateResult = extractTerminalControlModeUpdates(
      input: data,
      pendingInput: _terminalControlModeUpdatePendingInput,
    );
    _terminalControlModeUpdatePendingInput = modeUpdateResult.pendingInput;
    final previousColorSchemeUpdatesMode = _terminalColorSchemeUpdatesMode;
    final nextColorSchemeUpdatesMode = modeUpdateResult.colorSchemeUpdatesMode;
    if (nextColorSchemeUpdatesMode != null &&
        nextColorSchemeUpdatesMode != _terminalColorSchemeUpdatesMode) {
      _terminalColorSchemeUpdatesMode = nextColorSchemeUpdatesMode;
      if (nextColorSchemeUpdatesMode && !previousColorSchemeUpdatesMode) {
        sendTerminalThemeModeReport(reason: 'color_scheme_updates_enabled');
      }
    }
    final nextSynchronizedOutputMode = modeUpdateResult.synchronizedOutputMode;
    if (nextSynchronizedOutputMode != null &&
        nextSynchronizedOutputMode != _terminalSynchronizedOutputMode) {
      _terminalSynchronizedOutputMode = nextSynchronizedOutputMode;
    }
    final nextGraphemeClusterMode = modeUpdateResult.graphemeClusterMode;
    if (nextGraphemeClusterMode != null &&
        nextGraphemeClusterMode != _terminalGraphemeClusterMode) {
      _terminalGraphemeClusterMode = nextGraphemeClusterMode;
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
    synchronizedOutputMode: _terminalSynchronizedOutputMode,
    graphemeClusterMode: _terminalGraphemeClusterMode,
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
