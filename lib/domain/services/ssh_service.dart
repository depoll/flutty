import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../data/database/database.dart';
import '../../data/repositories/host_repository.dart';
import '../../data/repositories/key_repository.dart';
import '../../data/repositories/known_hosts_repository.dart';
import '../models/remote_multiplexer.dart';
import '../models/terminal_preview.dart';
import '../models/terminal_theme.dart';
import 'app_review_demo_service.dart';
import 'background_ssh_service.dart';
import 'clipboard_sharing_service.dart';
import 'diagnostics_log_service.dart';
import 'host_key_prompt_handler_provider.dart';
import 'host_key_verification.dart';
import 'interactive_auth_prompt.dart';
import 'local_notification_service.dart';
import 'port_forward_browser_service.dart';
import 'settings_service.dart';
import 'ssh_exec_queue.dart';
import 'telemetry_service.dart';
import 'terminal_hyperlink_tracker.dart';
import 'terminal_notification.dart';
import 'terminal_preview_graphics.dart';
import 'wifi_network_service.dart';
import 'windows_remote_powershell.dart';

part 'ssh_session_runtime.dart';

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
    final endIndex = _terminalTmuxPassthroughEndIndex(
      combinedInput,
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

/// Extracts terminal control mode changes from shell output.
///
/// Some TUIs enable DEC private mode 2031 to request a report when the
/// terminal switches between light and dark color schemes. Windows ConPTY
/// requests DEC private mode 9001 (win32-input-mode) when a session starts.
/// xterm.dart does not currently model either mode, so MonkeySSH tracks them
/// while scanning the same shell output used for other terminal control
/// queries.
({bool? colorSchemeUpdatesMode, bool? win32InputMode, String pendingInput})
extractTerminalControlModeUpdates({
  required String input,
  required String pendingInput,
}) {
  final combinedInput = pendingInput + input;
  bool? colorSchemeUpdatesMode;
  bool? win32InputMode;

  for (final match in _terminalPrivateModeSetResetPattern.allMatches(
    combinedInput,
  )) {
    final params = match.group(1)?.split(';') ?? const <String>[];
    final isSet = match.group(2) == 'h';
    if (params.contains('2031')) {
      colorSchemeUpdatesMode = isSet;
    }
    if (params.contains('9001')) {
      win32InputMode = isSet;
    }
  }

  return (
    colorSchemeUpdatesMode: colorSchemeUpdatesMode,
    win32InputMode: win32InputMode,
    pendingInput: _terminalControlQueryPendingSuffix(combinedInput),
  );
}

/// Re-encodes OSC and DCS responses so they survive a Windows ConPTY.
///
/// Windows ConPTY (conhost, used by Win32-OpenSSH) requests win32-input-mode
/// (`CSI ? 9001 h`) when a session starts. Its input-side parser strips raw
/// OSC and DCS sequences arriving on the input stream, so replies to terminal
/// color queries never reach the remote app. Wrapping each code unit of those
/// sequences as a win32-input-mode key event (`CSI Vk;Sc;Uc;Kd;Cs;Rc _`) makes
/// ConPTY decode them back to the original bytes for the foreground app. CSI
/// responses and regular keyboard input already pass through unmodified, so
/// only OSC/DCS sequences are re-encoded.
String encodeTerminalResponsesForWin32InputMode(String data) {
  if (!data.contains('\x1b]') && !data.contains('\x1bP')) {
    return data;
  }
  final output = StringBuffer();
  var cursor = 0;
  for (final match in _terminalOscOrDcsSequencePattern.allMatches(data)) {
    output.write(data.substring(cursor, match.start));
    _writeWin32InputModeKeyEvents(output, match.group(0)!);
    cursor = match.end;
  }
  output.write(data.substring(cursor));
  return output.toString();
}

void _writeWin32InputModeKeyEvents(StringBuffer output, String sequence) {
  for (final codeUnit in sequence.codeUnits) {
    // CSI Vk;Sc;Uc;Kd;Cs;Rc _ with only the Unicode char, key-down, and
    // repeat-count fields set, mirroring how Windows Terminal forwards
    // characters that have no associated virtual key.
    output
      ..write('\x1b[0;0;')
      ..write(codeUnit)
      ..write(';1;0;1_');
  }
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

/// Adapts remote terminal output so xterm.dart renders it correctly.
///
/// xterm.dart 4.0.0 tracks IRM (`CSI 4 h/l`) but does not shift existing cells
/// when printable characters arrive while the mode is active. Injecting ICH
/// before each printable cell preserves behavior from editors such as nano,
/// while [pendingInput] keeps split escape sequences from leaking printable
/// bytes into the renderer.
///
/// xterm.dart 4.0.0 also corrupts its line buffer when RI (`ESC M`) scrolls a
/// vertical margin region down. When cursor state is provided, that RI is
/// rewritten to IL (`CSI L`), which has the same effect at the top margin
/// without reusing detached buffer lines internally.
///
/// xterm.dart also treats private `CSI > ... m` keyboard modifier controls as
/// SGR attributes. Dropping those controls prevents TUIs such as OpenCode from
/// accidentally enabling underline/bold while painting spaces.
@visibleForTesting
({String output, String pendingInput, bool insertMode, int pendingScanOffset})
adaptTerminalInsertModeOutputForXterm({
  required String input,
  required String pendingInput,
  required bool insertMode,
  int pendingScanOffset = 0,
  int? terminalColumns,
  int? terminalRows,
  int? cursorColumn,
  int? cursorRow,
  int? marginTop,
  int? marginBottom,
  bool originMode = false,
}) {
  final combinedInput = pendingInput + input;
  final output = StringBuffer();
  var cursor = 0;
  var nextInsertMode = insertMode;
  final cursorTracker = _TerminalOutputCursorTracker(
    columns: terminalColumns,
    rows: terminalRows,
    cursorColumn: cursorColumn,
    cursorRow: cursorRow,
    marginTop: marginTop,
    marginBottom: marginBottom,
    originMode: originMode,
  );

  while (cursor < combinedInput.length) {
    final codeUnit = combinedInput.codeUnitAt(cursor);
    if (codeUnit == _terminalEscapeCodeUnit) {
      // Only the carried-over incomplete sequence (always at index 0) can
      // resume a prior scan; later sequences scan from their own body.
      final endIndex = _terminalEscapeSequenceEndIndex(
        combinedInput,
        cursor,
        resumeBodyFrom: cursor == 0 ? pendingScanOffset : 0,
      );
      if (endIndex == null) {
        // Still incomplete: we have now scanned to the end, so the next call
        // resumes one character back (to catch a split `ESC \` terminator).
        final scanned = combinedInput.length - cursor;
        return (
          output: output.toString(),
          pendingInput: combinedInput.substring(cursor),
          insertMode: nextInsertMode,
          pendingScanOffset: scanned > 1 ? scanned - 1 : 0,
        );
      }

      final sequence = combinedInput.substring(cursor, endIndex);
      if (!_shouldDropTerminalOutputSequenceForXterm(sequence)) {
        output.write(cursorTracker.adaptEscapeSequence(sequence));
        final insertModeUpdate = _terminalInsertModeUpdate(sequence);
        if (insertModeUpdate != null) {
          nextInsertMode = insertModeUpdate;
        }
      }
      cursor = endIndex;
      continue;
    }

    final rune = _terminalRuneAt(combinedInput, cursor);
    final runeLength = _terminalRuneLength(rune);
    if (nextInsertMode && _isTerminalGraphicRune(rune)) {
      final width = _terminalCellWidth(rune);
      for (var cell = 0; cell < width; cell += 1) {
        output.write(_terminalInsertBlankCharacterSequence);
      }
    }
    output.write(combinedInput.substring(cursor, cursor + runeLength));
    cursorTracker.writeRune(rune);
    cursor += runeLength;
  }

  return (
    output: output.toString(),
    pendingInput: '',
    insertMode: nextInsertMode,
    pendingScanOffset: 0,
  );
}

class _TerminalOutputCursorTracker {
  _TerminalOutputCursorTracker({
    required int? columns,
    required int? rows,
    required int? cursorColumn,
    required int? cursorRow,
    required int? marginTop,
    required int? marginBottom,
    required bool originMode,
  }) : _columns = columns != null && columns > 0 ? columns : null,
       _rows = rows != null && rows > 0 ? rows : null,
       _originMode = originMode {
    final validRows = _rows;
    final validColumns = _columns;
    if (validRows == null ||
        validColumns == null ||
        cursorColumn == null ||
        cursorRow == null) {
      return;
    }

    _cursorColumn = cursorColumn.clamp(0, validColumns);
    _cursorRow = cursorRow.clamp(0, validRows - 1);
    _marginTop = (marginTop ?? 0).clamp(0, validRows - 1);
    _marginBottom = (marginBottom ?? validRows - 1).clamp(0, validRows - 1);
    if (_marginTop! > _marginBottom!) {
      final top = _marginTop!;
      _marginTop = _marginBottom;
      _marginBottom = top;
    }
  }

  final int? _columns;
  final int? _rows;
  int? _cursorColumn;
  int? _cursorRow;
  int? _marginTop;
  int? _marginBottom;
  bool _originMode;

  bool get _hasPosition =>
      _columns != null &&
      _rows != null &&
      _cursorColumn != null &&
      _cursorRow != null &&
      _marginTop != null &&
      _marginBottom != null;

  String adaptEscapeSequence(String sequence) {
    if (sequence == _terminalReverseIndexSequence) {
      return _adaptReverseIndex();
    }

    _applyEscapeSequence(sequence);
    return sequence;
  }

  void writeRune(int rune) {
    if (!_hasPosition) {
      return;
    }

    switch (rune) {
      case _terminalBackspaceCodeUnit:
        _cursorColumn = math.max(_cursorColumn! - 1, 0);
      case _terminalHorizontalTabCodeUnit:
        _cursorColumn = math.min(((_cursorColumn! ~/ 8) + 1) * 8, _columns!);
      case _terminalLineFeedCodeUnit:
      case _terminalVerticalTabCodeUnit:
      case _terminalFormFeedCodeUnit:
        _lineFeed();
      case _terminalCarriageReturnCodeUnit:
        _cursorColumn = 0;
      default:
        final width = _terminalCellWidth(rune);
        if (width <= 0) {
          return;
        }
        final columns = _columns!;
        if (_cursorColumn! >= columns) {
          _lineFeed();
          _cursorColumn = 0;
        }
        _cursorColumn = math.min(_cursorColumn! + width, columns);
    }
  }

  String _adaptReverseIndex() {
    if (!_hasPosition) {
      return _terminalReverseIndexSequence;
    }

    if (_cursorRow == _marginTop) {
      final restoreColumn = _cursorColumn!;
      return restoreColumn == 0
          ? _terminalInsertLineSequence
          : '$_terminalInsertLineSequence\x1b[${restoreColumn + 1}G';
    }

    _cursorRow = math.max(_cursorRow! - 1, 0);
    return _terminalReverseIndexSequence;
  }

  void _applyEscapeSequence(String sequence) {
    if (!_hasPosition || sequence.length < 2) {
      return;
    }

    if (sequence.length == 2 &&
        sequence.codeUnitAt(1) == _terminalFullResetFinalCodeUnit) {
      _resetCursorState();
      return;
    }

    if (sequence.codeUnitAt(1) != _terminalCsiIntroducerCodeUnit) {
      return;
    }

    final finalCodeUnit = sequence.codeUnitAt(sequence.length - 1);
    final params = _terminalCsiNumericParams(sequence);
    final originModeUpdate = _terminalDecOriginModeUpdate(sequence);
    if (originModeUpdate != null) {
      _originMode = originModeUpdate;
      return;
    }

    switch (finalCodeUnit) {
      case _terminalCursorUpFinalCodeUnit:
        _moveCursorRows(-_terminalCsiParam(params, 0, defaultValue: 1));
      case _terminalCursorDownFinalCodeUnit:
        _moveCursorRows(_terminalCsiParam(params, 0, defaultValue: 1));
      case _terminalCursorForwardFinalCodeUnit:
        _moveCursorColumns(_terminalCsiParam(params, 0, defaultValue: 1));
      case _terminalCursorBackFinalCodeUnit:
        _moveCursorColumns(-_terminalCsiParam(params, 0, defaultValue: 1));
      case _terminalCursorNextLineFinalCodeUnit:
        _moveCursorRows(_terminalCsiParam(params, 0, defaultValue: 1));
        _cursorColumn = 0;
      case _terminalCursorPreviousLineFinalCodeUnit:
        _moveCursorRows(-_terminalCsiParam(params, 0, defaultValue: 1));
        _cursorColumn = 0;
      case _terminalCursorHorizontalAbsoluteFinalCodeUnit:
        _setCursorColumn(_terminalCsiParam(params, 0, defaultValue: 1) - 1);
      case _terminalCursorPositionFinalCodeUnit:
      case _terminalHorizontalVerticalPositionFinalCodeUnit:
        _setCursor(
          row: _terminalCsiParam(params, 0, defaultValue: 1) - 1,
          column: _terminalCsiParam(params, 1, defaultValue: 1) - 1,
        );
      case _terminalLinePositionAbsoluteFinalCodeUnit:
        _setCursorRow(_terminalCsiParam(params, 0, defaultValue: 1) - 1);
      case _terminalSetMarginsFinalCodeUnit:
        _setMargins(params);
      case _terminalInsertLinesFinalCodeUnit:
      case _terminalDeleteLinesFinalCodeUnit:
        _cursorColumn = 0;
    }
  }

  void _lineFeed() {
    final row = _cursorRow!;
    final marginTop = _marginTop!;
    final marginBottom = _marginBottom!;
    final inMargins = row >= marginTop && row <= marginBottom;
    if (inMargins && row == marginBottom) {
      return;
    }
    if (!inMargins && row >= _rows! - 1) {
      return;
    }
    _cursorRow = math.min(row + 1, _rows! - 1);
  }

  void _moveCursorRows(int offset) {
    _setCursorRow(_cursorRow! + offset);
  }

  void _moveCursorColumns(int offset) {
    _setCursorColumn(_cursorColumn! + offset);
  }

  void _setCursor({required int row, required int column}) {
    if (_originMode) {
      _cursorRow = (row + _marginTop!).clamp(0, _marginBottom!);
    } else {
      _setCursorRow(row);
    }
    _setCursorColumn(column);
  }

  void _setCursorRow(int row) {
    _cursorRow = row.clamp(0, _rows! - 1);
  }

  void _setCursorColumn(int column) {
    _cursorColumn = column.clamp(0, _columns! - 1);
  }

  void _setMargins(List<int?> params) {
    if (params.length > 2) {
      return;
    }

    final rows = _rows!;
    final top = _terminalCsiParam(params, 0, defaultValue: 1) - 1;
    final bottom = params.length >= 2 && params[1] != null && params[1] != 0
        ? params[1]! - 1
        : rows - 1;
    _marginTop = top.clamp(0, rows - 1);
    _marginBottom = bottom.clamp(0, rows - 1);
    if (_marginTop! > _marginBottom!) {
      final topMargin = _marginTop!;
      _marginTop = _marginBottom;
      _marginBottom = topMargin;
    }
  }

  void _resetCursorState() {
    _cursorColumn = 0;
    _cursorRow = 0;
    _marginTop = 0;
    _marginBottom = _rows! - 1;
    _originMode = false;
  }
}

final _terminalWindowQueryPattern = RegExp(r'\x1b\[([0-9;?]*)t');
final _terminalModeReportQueryPattern = RegExp(r'\x1b\[\?([0-9;]+)\$p');
final _terminalThemeModeQueryPattern = RegExp(r'\x1b\[\?996n');
final _terminalControlQueryPrefixPattern = RegExp(r'^\x1b(?:$|\[[0-9;?\$]*)$');
final _terminalPrivateModeSetResetPattern = RegExp(r'\x1b\[\?([0-9;]+)([hl])');
final _terminalOscOrDcsSequencePattern = RegExp(
  r'\x1b(?:\][^\x07\x1b]*(?:\x07|\x1b\\)|P[^\x1b]*\x1b\\)',
);
final _terminalCursorPositionReportPattern = RegExp(
  r'\x1b\[([0-9]+);([0-9]+)R',
);
final _terminalCsiNumericParamsPattern = RegExp(r'^[0-9;]*$');

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
const _terminalEscapeCodeUnit = 0x1B;
const _terminalBellCodeUnit = 0x07;
const _terminalBackspaceCodeUnit = 0x08;
const _terminalHorizontalTabCodeUnit = 0x09;
const _terminalLineFeedCodeUnit = 0x0A;
const _terminalVerticalTabCodeUnit = 0x0B;
const _terminalFormFeedCodeUnit = 0x0C;
const _terminalCarriageReturnCodeUnit = 0x0D;
const _terminalCsiIntroducerCodeUnit = 0x5B;
const _terminalDcsIntroducerCodeUnit = 0x50;
const _terminalOscIntroducerCodeUnit = 0x5D;
const _terminalSosIntroducerCodeUnit = 0x58;
const _terminalPmIntroducerCodeUnit = 0x5E;
const _terminalApcIntroducerCodeUnit = 0x5F;
const _terminalStringTerminatorCodeUnit = 0x5C;
const _terminalDeleteCodeUnit = 0x7F;
const _terminalCursorUpFinalCodeUnit = 0x41;
const _terminalCursorDownFinalCodeUnit = 0x42;
const _terminalCursorForwardFinalCodeUnit = 0x43;
const _terminalCursorBackFinalCodeUnit = 0x44;
const _terminalCursorNextLineFinalCodeUnit = 0x45;
const _terminalCursorPreviousLineFinalCodeUnit = 0x46;
const _terminalCursorHorizontalAbsoluteFinalCodeUnit = 0x47;
const _terminalCursorPositionFinalCodeUnit = 0x48;
const _terminalInsertLinesFinalCodeUnit = 0x4C;
const _terminalDeleteLinesFinalCodeUnit = 0x4D;
const _terminalHorizontalVerticalPositionFinalCodeUnit = 0x66;
const _terminalLinePositionAbsoluteFinalCodeUnit = 0x64;
const _terminalSetMarginsFinalCodeUnit = 0x72;
const _terminalInsertMode = 4;
const _terminalOriginMode = 6;
const _terminalSetModeFinalCodeUnit = 0x68;
const _terminalResetModeFinalCodeUnit = 0x6C;
const _terminalSoftResetFinalCodeUnit = 0x70;
const _terminalFullResetFinalCodeUnit = 0x63;
const _terminalPrivateMarkerCodeUnit = 0x3E;
const _terminalSelectGraphicRenditionFinalCodeUnit = 0x6D;
const _terminalInsertBlankCharacterSequence = '\x1b[@';
const _terminalReverseIndexSequence = '\x1bM';
const _terminalInsertLineSequence = '\x1b[L';
const _escapedTerminalEscape = '$_terminalEscape$_terminalEscape';
const _terminalStringTerminator = '$_terminalEscape\\';
const _terminalTmuxPassthroughStart = '${_terminalEscape}Ptmux;';

String _formatTerminalModeReport(int mode, int status) =>
    '\x1b[?$mode;$status\$y';

int _terminalTmuxPassthroughEndIndex(String input, int payloadStart) {
  var index = payloadStart;
  while (index < input.length - 1) {
    if (input[index] != _terminalEscape) {
      index += 1;
      continue;
    }

    final next = input[index + 1];
    if (next == _terminalEscape) {
      index += 2;
      continue;
    }
    if (next == r'\') {
      return index;
    }
    index += 1;
  }
  return -1;
}

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

/// Finds the end index of the escape sequence beginning at [start].
///
/// [resumeBodyFrom] lets a caller that already scanned part of an incomplete
/// sequence (carried as `pendingInput`) resume the terminator search instead of
/// rescanning from the sequence body. This keeps re-feeding a long sequence
/// (e.g. a multi-megabyte Kitty graphics APC split across slices) O(n) overall
/// rather than O(n^2). The caller must include a one-character overlap so a
/// two-byte ST terminator (`ESC \`) split across the boundary is still found.
int? _terminalEscapeSequenceEndIndex(
  String input,
  int start, {
  int resumeBodyFrom = 0,
}) {
  if (start + 1 >= input.length) {
    return null;
  }

  final introducer = input.codeUnitAt(start + 1);
  switch (introducer) {
    case _terminalCsiIntroducerCodeUnit:
      return _terminalCsiEndIndex(input, math.max(start + 2, resumeBodyFrom));
    case _terminalDcsIntroducerCodeUnit:
    case _terminalOscIntroducerCodeUnit:
    case _terminalSosIntroducerCodeUnit:
    case _terminalPmIntroducerCodeUnit:
    case _terminalApcIntroducerCodeUnit:
      return _terminalStringEndIndex(
        input,
        math.max(start + 2, resumeBodyFrom),
      );
  }

  var cursor = math.max(start + 1, resumeBodyFrom);
  while (cursor < input.length &&
      _isTerminalEscapeIntermediate(input.codeUnitAt(cursor))) {
    cursor += 1;
  }
  if (cursor >= input.length) {
    return null;
  }
  return cursor + 1;
}

int? _terminalCsiEndIndex(String input, int start) {
  var cursor = start;
  while (cursor < input.length) {
    final codeUnit = input.codeUnitAt(cursor);
    if (codeUnit >= 0x40 && codeUnit <= 0x7E) {
      return cursor + 1;
    }
    cursor += 1;
  }
  return null;
}

int? _terminalStringEndIndex(String input, int start) {
  var cursor = start;
  while (cursor < input.length) {
    final codeUnit = input.codeUnitAt(cursor);
    if (codeUnit == _terminalBellCodeUnit) {
      return cursor + 1;
    }
    if (codeUnit == _terminalEscapeCodeUnit) {
      if (cursor + 1 >= input.length) {
        return null;
      }
      if (input.codeUnitAt(cursor + 1) == _terminalStringTerminatorCodeUnit) {
        return cursor + 2;
      }
      cursor += 1;
      continue;
    }
    cursor += 1;
  }
  return null;
}

bool _isTerminalEscapeIntermediate(int codeUnit) =>
    codeUnit >= 0x20 && codeUnit <= 0x2F;

bool? _terminalInsertModeUpdate(String sequence) {
  if (sequence.length < 2 ||
      sequence.codeUnitAt(0) != _terminalEscapeCodeUnit) {
    return null;
  }
  if (sequence.length == 2 &&
      sequence.codeUnitAt(1) == _terminalFullResetFinalCodeUnit) {
    return false;
  }
  if (sequence.length < 4 ||
      sequence.codeUnitAt(1) != _terminalCsiIntroducerCodeUnit) {
    return null;
  }

  final finalCodeUnit = sequence.codeUnitAt(sequence.length - 1);
  final params = sequence.substring(2, sequence.length - 1);
  if (finalCodeUnit == _terminalSoftResetFinalCodeUnit &&
      (params == '!' || params.endsWith('"'))) {
    return false;
  }
  if (finalCodeUnit != _terminalSetModeFinalCodeUnit &&
      finalCodeUnit != _terminalResetModeFinalCodeUnit) {
    return null;
  }

  if (params.startsWith('?')) {
    return null;
  }
  for (final param in params.split(';')) {
    if (int.tryParse(param) == _terminalInsertMode) {
      return finalCodeUnit == _terminalSetModeFinalCodeUnit;
    }
  }
  return null;
}

bool? _terminalDecOriginModeUpdate(String sequence) {
  if (sequence.length < 5 ||
      sequence.codeUnitAt(0) != _terminalEscapeCodeUnit ||
      sequence.codeUnitAt(1) != _terminalCsiIntroducerCodeUnit) {
    return null;
  }

  final finalCodeUnit = sequence.codeUnitAt(sequence.length - 1);
  if (finalCodeUnit != _terminalSetModeFinalCodeUnit &&
      finalCodeUnit != _terminalResetModeFinalCodeUnit) {
    return null;
  }

  final params = sequence.substring(2, sequence.length - 1);
  if (!params.startsWith('?')) {
    return null;
  }

  for (final param in params.substring(1).split(';')) {
    if (int.tryParse(param) == _terminalOriginMode) {
      return finalCodeUnit == _terminalSetModeFinalCodeUnit;
    }
  }
  return null;
}

bool _shouldDropTerminalOutputSequenceForXterm(String sequence) {
  if (sequence.length < 4 ||
      sequence.codeUnitAt(0) != _terminalEscapeCodeUnit ||
      sequence.codeUnitAt(1) != _terminalCsiIntroducerCodeUnit ||
      sequence.codeUnitAt(2) != _terminalPrivateMarkerCodeUnit ||
      sequence.codeUnitAt(sequence.length - 1) !=
          _terminalSelectGraphicRenditionFinalCodeUnit) {
    return false;
  }

  final params = sequence.substring(3, sequence.length - 1);
  return _terminalCsiNumericParamsPattern.hasMatch(params);
}

List<int?> _terminalCsiNumericParams(String sequence) {
  if (sequence.length < 3 ||
      sequence.codeUnitAt(0) != _terminalEscapeCodeUnit ||
      sequence.codeUnitAt(1) != _terminalCsiIntroducerCodeUnit) {
    return const [];
  }

  final params = sequence.substring(2, sequence.length - 1);
  if (params.isEmpty) {
    return const [];
  }
  if (!_terminalCsiNumericParamsPattern.hasMatch(params)) {
    return const [];
  }
  return params
      .split(';')
      .map((param) => param.isEmpty ? null : int.tryParse(param))
      .toList();
}

int _terminalCsiParam(
  List<int?> params,
  int index, {
  required int defaultValue,
}) {
  if (index >= params.length || params[index] == null || params[index] == 0) {
    return defaultValue;
  }
  return params[index]!;
}

int _terminalRuneAt(String input, int index) {
  final first = input.codeUnitAt(index);
  if (_isTerminalHighSurrogate(first) && index + 1 < input.length) {
    final second = input.codeUnitAt(index + 1);
    if (_isTerminalLowSurrogate(second)) {
      return 0x10000 + ((first - 0xD800) << 10) + second - 0xDC00;
    }
  }
  return first;
}

int _terminalRuneLength(int rune) => rune > 0xFFFF ? 2 : 1;

bool _isTerminalHighSurrogate(int codeUnit) =>
    codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

bool _isTerminalLowSurrogate(int codeUnit) =>
    codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

bool _isTerminalGraphicRune(int rune) =>
    rune >= 0x20 &&
    rune != _terminalDeleteCodeUnit &&
    !(rune >= 0x80 && rune <= 0x9F);

int _terminalCellWidth(int rune) {
  if (!_isTerminalGraphicRune(rune) || _isTerminalZeroWidthRune(rune)) {
    return 0;
  }
  if (_isTerminalWideRune(rune)) {
    return 2;
  }
  return 1;
}

bool _isTerminalZeroWidthRune(int rune) =>
    rune == 0x200D ||
    (rune >= 0x0300 && rune <= 0x036F) ||
    (rune >= 0x1AB0 && rune <= 0x1AFF) ||
    (rune >= 0x1DC0 && rune <= 0x1DFF) ||
    (rune >= 0x20D0 && rune <= 0x20FF) ||
    (rune >= 0xFE00 && rune <= 0xFE0F) ||
    (rune >= 0xFE20 && rune <= 0xFE2F) ||
    (rune >= 0x1F3FB && rune <= 0x1F3FF) ||
    (rune >= 0xE0100 && rune <= 0xE01EF);

bool _isTerminalWideRune(int rune) =>
    rune >= 0x1100 &&
    (rune <= 0x115F ||
        rune == 0x2329 ||
        rune == 0x232A ||
        (rune >= 0x2E80 && rune <= 0xA4CF && rune != 0x303F) ||
        (rune >= 0xAC00 && rune <= 0xD7A3) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0xFE10 && rune <= 0xFE19) ||
        (rune >= 0xFE30 && rune <= 0xFE6F) ||
        (rune >= 0xFF00 && rune <= 0xFF60) ||
        (rune >= 0xFFE0 && rune <= 0xFFE6) ||
        (rune >= 0x1F300 && rune <= 0x1FAFF) ||
        (rune >= 0x20000 && rune <= 0x3FFFD));

bool _hasValidTerminalWindowMetrics(TerminalWindowMetrics? metrics) =>
    metrics != null &&
    metrics.columns > 0 &&
    metrics.rows > 0 &&
    metrics.pixelWidth > 0 &&
    metrics.pixelHeight > 0;

String _terminalControlQueryPendingSuffix(String input) {
  // Retain a trailing partial control query so it can be completed by the next
  // slice. Scan back far enough to cover the longest supported query (a
  // multi-parameter mode report can exceed a short window); slicing terminal
  // output more finely makes such a split more reachable.
  const maxPendingQueryLength = 64;
  final windowStart = input.length > maxPendingQueryLength
      ? input.length - maxPendingQueryLength
      : 0;
  for (var index = input.length - 1; index >= windowStart; index -= 1) {
    if (input.codeUnitAt(index) != _terminalEscapeCodeUnit) {
      continue;
    }
    final suffix = input.substring(index);
    return _terminalControlQueryPrefixPattern.hasMatch(suffix) ? suffix : '';
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
      SSHUserInfoRequestHandler? onUserInfoRequest,
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

/// Resolved password / keyboard-interactive handlers for a connection.
class _InteractiveAuthHandlers {
  const _InteractiveAuthHandlers({
    this.onPasswordRequest,
    this.onUserInfoRequest,
  });

  final SSHPasswordRequestHandler? onPasswordRequest;
  final SSHUserInfoRequestHandler? onUserInfoRequest;
}

/// Tracks whether an interactive authentication prompt is currently open so
/// the authentication timeout can pause while the user types.
class _InteractiveAuthGate {
  int _activePrompts = 0;

  /// Invoked whenever a prompt opens or closes.
  void Function()? onActivityChanged;

  /// Whether at least one interactive prompt is currently awaiting input.
  bool get isPrompting => _activePrompts > 0;

  /// Runs [action] while marking a prompt as active for its duration.
  Future<T> guard<T>(Future<T> Function() action) async {
    _activePrompts++;
    onActivityChanged?.call();
    try {
      return await action();
    } finally {
      _activePrompts--;
      onActivityChanged?.call();
    }
  }
}

/// Service for managing SSH connections.
class SshService {
  /// Creates a new [SshService].
  SshService({
    this.hostRepository,
    this.keyRepository,
    this.knownHostsRepository,
    this.hostKeyPromptHandler,
    this.interactiveAuthPromptHandler,
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

  /// UI callback used to collect passwords / keyboard-interactive responses
  /// when the server issues a challenge and no stored credential answers it.
  final InteractiveAuthPromptHandler? interactiveAuthPromptHandler;

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
    var preflightPhase = 'start';
    DiagnosticsLogService.instance.info(
      'ssh.connect',
      'connect_to_host_start',
      fields: {'hostId': hostId},
    );
    try {
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

      preflightPhase = 'load_host';
      final host = await hostRepository!.getById(hostId);
      if (host == null) {
        DiagnosticsLogService.instance.warning(
          'ssh.connect',
          'connect_to_host_missing_host',
          fields: {'hostId': hostId},
        );
        return const SshConnectionResult(
          success: false,
          error: 'Host not found',
        );
      }
      DiagnosticsLogService.instance.info(
        'ssh.connect',
        'connect_to_host_loaded_host',
        fields: {
          'hostId': hostId,
          'hasPassword': host.password != null,
          'hasKeyId': host.keyId != null,
          'hasJumpHost': host.jumpHostId != null,
        },
      );

      if (isAppReviewDemoHost(host)) {
        return _connectToAppReviewDemoHost(
          host,
          useHostThemeOverrides: useHostThemeOverrides,
          onProgress: onProgress,
        );
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
        preflightPhase = 'load_auto_keys';
        final keyLoadResult = await keyRepository!.getAllDecryptable();
        if (keyLoadResult.unreadableCount > 0) {
          DiagnosticsLogService.instance.warning(
            'ssh.connect',
            'auto_key_load_skipped_unreadable',
            fields: {
              'hostId': hostId,
              'unreadableCount': keyLoadResult.unreadableCount,
              'loadedCount': keyLoadResult.keys.length,
              'errorType': keyLoadResult.firstUnreadableErrorType,
            },
          );
        }
        final keys = keyLoadResult.keys;
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
        preflightPhase = 'load_host_key';
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
          onProgress?.call(
            const ConnectionProgressUpdate(
              state: SshConnectionState.connecting,
              message: 'Checking Wi-Fi network for jump host bypass…',
            ),
          );
          preflightPhase = 'check_wifi_bypass';
          final permission = await wifiNetworkService.requestPermission();
          String? currentSsid;
          if (permission == WifiPermissionStatus.granted) {
            currentSsid = await wifiNetworkService.getCurrentSsid();
            skipJumpHost = shouldSkipJumpHostForSsid(
              currentSsid: currentSsid,
              skipJumpHostOnSsids: host.skipJumpHostOnSsids,
            );
          } else {
            onProgress?.call(
              const ConnectionProgressUpdate(
                state: SshConnectionState.connecting,
                message: 'Wi-Fi permission denied. Using jump host…',
              ),
            );
          }
          DiagnosticsLogService.instance.info(
            'ssh.connect',
            'jump_host_ssid_check',
            fields: {
              'hostId': hostId,
              'permissionStatus': permission.name,
              'hasCurrentSsid': currentSsid != null,
              'skipJumpHost': skipJumpHost,
            },
          );
        }
        if (!skipJumpHost) {
          preflightPhase = 'load_jump_host';
          final jumpHost = await hostRepository!.getById(host.jumpHostId!);
          if (jumpHost != null) {
            SshKey? jumpKey;
            List<SshKey>? jumpIdentityKeys;
            if (jumpHost.keyId != null && keyRepository != null) {
              preflightPhase = 'load_jump_host_key';
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

      preflightPhase = 'build_config';
      final config = SshConnectionConfig.fromHost(
        host,
        key: key,
        identityKeys: identityKeys,
        jumpHostConfig: jumpHostConfig,
      );

      preflightPhase = 'connect';
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
    } on Exception catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.connect',
        'connect_to_host_preflight_failed',
        fields: {
          'hostId': hostId,
          'phase': preflightPhase,
          'errorType': e.runtimeType,
        },
      );
      return const SshConnectionResult(
        success: false,
        error:
            'Connection setup failed. Check saved credentials and try again.',
      );
    }
  }

  Future<SshConnectionResult> _connectToAppReviewDemoHost(
    Host host, {
    required bool useHostThemeOverrides,
    ConnectionProgressCallback? onProgress,
  }) async {
    onProgress?.call(
      const ConnectionProgressUpdate(
        state: SshConnectionState.connecting,
        message: 'Starting local App Review demo session…',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    onProgress?.call(
      const ConnectionProgressUpdate(
        state: SshConnectionState.authenticating,
        message: 'Preparing in-app demo shell…',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));

    final config = SshConnectionConfig.fromHost(host);
    final client = _AppReviewDemoSshClient(host);
    final connectionId = _nextConnectionId++;
    _sessions[connectionId] = SshSession(
      connectionId: connectionId,
      hostId: host.id,
      client: client,
      config: config,
      terminalThemeLightId: useHostThemeOverrides
          ? host.terminalThemeLightId
          : null,
      terminalThemeDarkId: useHostThemeOverrides
          ? host.terminalThemeDarkId
          : null,
    );
    await hostRepository?.updateLastConnected(host.id);
    DiagnosticsLogService.instance.info(
      'ssh.connect',
      'app_review_demo_connected',
      fields: {'hostId': host.id, 'connectionId': connectionId},
    );
    return SshConnectionResult(
      success: true,
      client: client,
      connectionId: connectionId,
    );
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
      final authGate = _InteractiveAuthGate();
      final authHandlers = _buildInteractiveAuthHandlers(config, authGate);

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
          onPasswordRequest: authHandlers.onPasswordRequest,
          onUserInfoRequest: authHandlers.onUserInfoRequest,
          identities: _parseIdentities(config),
          keepAliveInterval: config.keepAliveInterval,
        );

        // Bound authentication waits so the progress dialog can surface a
        // recoverable error instead of hanging indefinitely.
        await _awaitAuthentication(
          client,
          authGate,
          timeout: config.connectionTimeout,
          isJumpHost: isJumpHost,
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
            rejectedCallbackFingerprint = _formatCallbackHostKeyFingerprint(
              fingerprint,
            );
          }
          return trusted;
        },
        onPasswordRequest: authHandlers.onPasswordRequest,
        onUserInfoRequest: authHandlers.onUserInfoRequest,
        identities: _parseIdentities(config),
        keepAliveInterval: config.keepAliveInterval,
      );

      try {
        await _awaitAuthentication(
          client,
          authGate,
          timeout: config.connectionTimeout,
          isJumpHost: isJumpHost,
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
          onPasswordRequest: authHandlers.onPasswordRequest,
          onUserInfoRequest: authHandlers.onUserInfoRequest,
          identities: _parseIdentities(config),
          keepAliveInterval: config.keepAliveInterval,
        );

        await _awaitAuthentication(
          client,
          authGate,
          timeout: config.connectionTimeout,
          isJumpHost: isJumpHost,
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

  /// Builds the password / keyboard-interactive handlers for a connection.
  ///
  /// When the host has a stored password it is used directly (and also
  /// answers a simple keyboard-interactive password prompt). Otherwise, if an
  /// [interactiveAuthPromptHandler] is available, the user is prompted so a
  /// server-issued password challenge can be answered from the UI.
  _InteractiveAuthHandlers _buildInteractiveAuthHandlers(
    SshConnectionConfig config,
    _InteractiveAuthGate gate,
  ) {
    final staticPassword = config.password;
    final promptHandler = interactiveAuthPromptHandler;
    final hostLabel = '${config.username}@${config.hostname}:${config.port}';

    SSHPasswordRequestHandler? onPasswordRequest;
    if (staticPassword != null) {
      onPasswordRequest = () => staticPassword;
    } else if (promptHandler != null) {
      onPasswordRequest = () => gate.guard(() async {
        final responses = await promptHandler(
          SshAuthChallenge(
            hostLabel: hostLabel,
            username: config.username,
            name: '',
            instruction: '',
            prompts: const [SshAuthPrompt(prompt: 'Password:', echo: false)],
          ),
        );
        if (responses == null || responses.isEmpty) {
          return null;
        }
        return responses.first;
      });
    }

    SSHUserInfoRequestHandler? onUserInfoRequest;
    if (staticPassword != null || promptHandler != null) {
      onUserInfoRequest = (request) async {
        final prompts = request.prompts;
        // A keyboard-interactive info request may legitimately carry zero
        // prompts (e.g. an informational banner, RFC 4256). It must be
        // answered with an empty response list rather than prompting the user.
        if (prompts.isEmpty) {
          return const <String>[];
        }
        // Reuse the stored password only for a single hidden prompt that
        // clearly asks for a password, so OTP/2FA/password-change challenges
        // still reach the user instead of silently receiving the saved
        // password (which the server would reject, breaking the login).
        if (staticPassword != null &&
            prompts.length == 1 &&
            !prompts.first.echo &&
            _isPlainPasswordPrompt(
              request.name,
              request.instruction,
              prompts.first.promptText,
            )) {
          return <String>[staticPassword];
        }
        if (promptHandler == null) {
          return null;
        }
        return gate.guard(
          () => promptHandler(
            SshAuthChallenge(
              hostLabel: hostLabel,
              username: config.username,
              name: request.name,
              instruction: request.instruction,
              prompts: prompts
                  .map(
                    (prompt) => SshAuthPrompt(
                      prompt: prompt.promptText,
                      echo: prompt.echo,
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        );
      };
    }

    return _InteractiveAuthHandlers(
      onPasswordRequest: onPasswordRequest,
      onUserInfoRequest: onUserInfoRequest,
    );
  }

  /// Whether a single keyboard-interactive prompt is unambiguously asking for
  /// an account password (rather than an OTP/2FA code or a new password during
  /// a password change), so a stored password can be safely reused to answer
  /// it. Errs toward `false`: unknown prompts fall through to the user.
  static bool _isPlainPasswordPrompt(
    String name,
    String instruction,
    String promptText,
  ) {
    final prompt = promptText.toLowerCase();
    if (!prompt.contains('password') && !prompt.contains('passphrase')) {
      return false;
    }
    final haystack = '$name\n$instruction\n$promptText'.toLowerCase();
    const nonPasswordMarkers = <String>[
      'one-time',
      'one time',
      'otp',
      'passcode',
      'verification',
      'authenticator',
      'token',
      '2fa',
      'mfa',
      'second factor',
      'two-factor',
      'two factor',
      'duo',
      'yubikey',
      'totp',
      'hotp',
      'security key',
      'new password',
      'new passphrase',
      'retype',
      're-enter',
      'reenter',
      'confirm',
      'change',
    ];
    return !nonPasswordMarkers.any(haystack.contains);
  }

  /// Awaits SSH authentication with a timeout that pauses while the user is
  /// answering an interactive prompt, so slow password entry does not abort
  /// the connection. Each time a prompt closes the timeout is refreshed to
  /// allow the following network round-trip to complete.
  Future<void> _awaitAuthentication(
    SSHClient client,
    _InteractiveAuthGate gate, {
    required Duration timeout,
    required bool isJumpHost,
  }) {
    final completer = Completer<void>();
    Timer? timer;

    void arm() {
      timer?.cancel();
      timer = Timer(timeout, () {
        if (gate.isPrompting) {
          arm();
          return;
        }
        if (!completer.isCompleted) {
          completer.completeError(
            TimeoutException(
              isJumpHost
                  ? 'Jump host authentication timed out'
                  : 'Authentication timed out',
            ),
          );
        }
      });
    }

    client.authenticated.then<void>(
      (_) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    gate.onActivityChanged = arm;
    arm();

    return completer.future.whenComplete(() {
      timer?.cancel();
      if (identical(gate.onActivityChanged, arm)) {
        gate.onActivityChanged = null;
      }
    });
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
          callbackFingerprint = _formatCallbackHostKeyFingerprint(fingerprint);
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
        !_hostKeyFingerprintMatchesPresentedKey(
          presentedHostKey,
          callbackFingerprint,
        )) {
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
    secondFingerprint: _formatCallbackHostKeyFingerprint(fingerprint),
    secondEncodedHostKey: '',
  );

  bool _probedHostKeyMatchesCallback(
    VerifiedHostKey presentedHostKey,
    Uint8List fingerprint,
  ) => _hostKeyFingerprintMatchesPresentedKey(
    presentedHostKey,
    _formatCallbackHostKeyFingerprint(fingerprint),
  );

  bool _hostKeyFingerprintMatchesPresentedKey(
    VerifiedHostKey presentedHostKey,
    String callbackFingerprint,
  ) => sshHostTrustMatches(
    firstFingerprint: presentedHostKey.fingerprint,
    firstEncodedHostKey: presentedHostKey.encodedHostKey,
    secondFingerprint: callbackFingerprint,
    secondEncodedHostKey: '',
  );

  String _formatCallbackHostKeyFingerprint(Uint8List fingerprint) {
    final openSshFingerprint = _tryDecodeOpenSshHostKeyFingerprint(fingerprint);
    if (openSshFingerprint != null) {
      return openSshFingerprint;
    }
    return _formatLegacyFingerprintBytes(fingerprint);
  }

  String? _tryDecodeOpenSshHostKeyFingerprint(Uint8List fingerprint) {
    try {
      final text = utf8.decode(fingerprint);
      if (text.startsWith('SHA256:')) {
        return text;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

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
    SSHUserInfoRequestHandler? onUserInfoRequest,
    List<SSHKeyPair>? identities,
    Duration? keepAliveInterval,
  }) => SSHClient(
    socket,
    username: username,
    onVerifyHostKey: onVerifyHostKey,
    onPasswordRequest: onPasswordRequest,
    onUserInfoRequest: onUserInfoRequest,
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

String? _diagnosticClosedSshConnectionErrorReason(Object error) {
  if (error is! SSHStateError) {
    return null;
  }
  final normalized = error.message.toLowerCase();
  if (normalized.contains('transport is closed')) {
    return 'transport_closed';
  }
  if (normalized.contains('connection closed')) {
    return 'connection_closed';
  }
  return null;
}

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
  if (trimmed.contains('FLUTTY_MODE=') ||
      trimmed.contains('__FLUTTY_COMPLETION__') ||
      trimmed.contains('__FLUTTY_ZSH_NATIVE_DONE__') ||
      trimmed.contains('__FLUTTY_HISTORY_DONE__')) {
    return 'shell_completion';
  }
  if (trimmed.startsWith('tmux ') ||
      trimmed.startsWith('tmux -u ') ||
      trimmed.contains(' tmux ') ||
      trimmed.contains('/tmux ')) {
    return 'tmux';
  }
  if (trimmed.contains('__flutty_agent_discovery_exec_done__')) {
    return 'agent_session_discovery';
  }
  if (trimmed.contains('.copilot/session-state')) {
    return 'active_session_metadata';
  }
  if (trimmed.contains('command -v')) {
    return 'command_detection';
  }
  if (trimmed.contains('__flutty_tmux_exec_done__')) {
    return 'tmux_marked_exec';
  }
  return 'ssh_exec';
}

/// Whether [remoteVersion] — the SSH server identification string, e.g.
/// `SSH-2.0-OpenSSH_for_Windows_9.5` — indicates a Windows remote host.
///
/// Windows OpenSSH launches `cmd.exe` or PowerShell (not a POSIX shell) for
/// interactive sessions and exec channels, so POSIX-only behaviour (the
/// truecolor login-shell bootstrap, tmux/MonkeyMux, `~/.profile` sourcing,
/// shell completion, agent-session discovery) must be skipped when this is
/// true. Returns `false` when the identification string is unknown so hosts
/// default to the POSIX path.
bool remoteVersionIndicatesWindows(String? remoteVersion) {
  if (remoteVersion == null || remoteVersion.isEmpty) {
    return false;
  }
  return remoteVersion.toLowerCase().contains('windows');
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
    String? monkeyMuxClientId,
  }) : monkeyMuxClientId =
           monkeyMuxClientId ?? _createMonkeyMuxClientId(connectionId),
       createdAt = DateTime.now();

  static const _previewRefreshInterval = Duration(milliseconds: 150);
  static const _shellIoDiagnosticsInterval = Duration(seconds: 1);
  static const _sftpOpenRetryDelays = [
    Duration(milliseconds: 250),
    Duration(milliseconds: 750),
  ];
  static const _previewLineCount = 17;
  static const _previewMaxChars = 1700;
  static final _monkeyMuxClientIdRandom = math.Random.secure();
  static final _previewSanitizerPattern = RegExp(r'[\x00-\x08\x0B-\x1F\x7F]');
  static final _windowTitleSanitizerPattern = RegExp(r'[\x00-\x1F\x7F]');

  static String _createMonkeyMuxClientId(int connectionId) {
    final random = List<String>.generate(
      4,
      (_) => _monkeyMuxClientIdRandom
          .nextInt(1 << 32)
          .toRadixString(16)
          .padLeft(8, '0'),
      growable: false,
    ).join();
    return 'monkeyssh-$connectionId-$random';
  }

  /// The connection ID for this active session.
  final int connectionId;

  /// Unique foreground-client identity shared by MonkeyMux attach and control
  /// channels for this SSH session.
  final String monkeyMuxClientId;

  /// The host ID this session is connected to.
  final int hostId;

  /// The SSH client.
  final SSHClient client;

  /// The SSH server identification string reported during the handshake, e.g.
  /// `SSH-2.0-OpenSSH_for_Windows_9.5`. Null until the handshake completes.
  String? get remoteSoftwareVersion => client.remoteVersion;

  /// Whether the remote host is Windows (its default shell is `cmd.exe` or
  /// PowerShell rather than a POSIX shell), detected from
  /// [remoteSoftwareVersion].
  ///
  /// When true, POSIX-only session behaviour — the truecolor login-shell
  /// bootstrap, tmux detection and `~/.profile` sourcing — is skipped because
  /// those commands fail on `cmd.exe`/PowerShell (e.g.
  /// `'exec' is not recognized...`). MonkeyMux, agent-session discovery and
  /// shell completion instead take Windows-aware paths (a ConPTY helper and
  /// PowerShell `-EncodedCommand` probes respectively).
  bool get remoteIsWindows =>
      remoteVersionIndicatesWindows(remoteSoftwareVersion);

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

  /// The terminal multiplexer backend currently attached in this session.
  RemoteMuxBackend? remoteMuxBackend;

  bool _canTerminalResizeFromHost() =>
      remoteMuxBackend == RemoteMuxBackend.monkeyMux;

  /// The terminal multiplexer session name currently attached in this session.
  String? remoteMuxSessionName;

  /// Whether the attached MonkeyMux server publishes its shared PTY grid size.
  bool monkeyMuxViewportClippingEnabled = false;

  /// Whether OSC 52 clipboard sharing is enabled for this session.
  bool clipboardSharingEnabled;

  /// Whether the remote side may read the local clipboard.
  bool localClipboardReadEnabled;

  /// When the session was created.
  final DateTime createdAt;

  final ClipboardSharingService _clipboardSharingService =
      const ClipboardSharingService();

  late final _SshSessionRuntime _runtime = _SshSessionRuntime(this);

  TerminalThemeData? _terminalTheme;

  /// The active terminal theme used to answer remote OSC color queries.
  TerminalThemeData? get terminalTheme => _terminalTheme;

  /// Updates the active terminal theme and notifies preview listeners.
  set terminalTheme(TerminalThemeData? theme) {
    setTerminalTheme(theme);
  }

  /// Whether the foreground app requested xterm color-scheme update reports.
  bool get terminalColorSchemeUpdatesMode =>
      _runtime.terminalColorSchemeUpdatesMode;

  /// Whether the remote requested win32-input-mode (DEC private mode 9001).
  ///
  /// Only Windows ConPTY (conhost) requests this mode, so it doubles as a
  /// protocol-level signal that a ConPTY sits between MonkeySSH and the
  /// foreground app.
  bool get terminalWin32InputMode => _runtime.terminalWin32InputMode;

  /// Tracks OSC 8 hyperlinks rendered in the persistent terminal.
  final terminalHyperlinkTracker = TerminalHyperlinkTracker();

  final _previewListeners = <VoidCallback>{};
  final _metadataListeners = <VoidCallback>{};
  final _connectionHealthFailures =
      StreamController<_SshConnectionHealthFailure>.broadcast();
  final _terminalNotificationParser = TerminalNotificationParser();
  final _terminalNotifications =
      StreamController<TerminalNotificationRequest>.broadcast();
  bool _connectionHealthFailureReported = false;
  String? _terminalPreview;
  TerminalPreviewSnapshot? _terminalPreviewSnapshot;
  String? _windowTitle;
  String? _iconName;
  Uri? _workingDirectory;
  TerminalShellStatus? _shellStatus;
  int? _lastExitCode;
  SftpClient? _sftpClient;
  Future<SftpClient>? _sftpClientFuture;

  /// The persistent terminal for this session. Created on first shell open.
  Terminal? get terminal => _runtime.terminal;

  /// A plain-text preview of the latest terminal content.
  String? get terminalPreview => _terminalPreview;

  /// A styled preview of the latest terminal content.
  TerminalPreviewSnapshot? get terminalPreviewSnapshot =>
      _terminalPreviewSnapshot;

  Stream<_SshConnectionHealthFailure> get _connectionHealthFailureStream =>
      _connectionHealthFailures.stream;

  /// Desktop-notification requests emitted by the remote shell via OSC 9 / 777
  /// / 99 escape sequences.
  Stream<TerminalNotificationRequest> get terminalNotifications =>
      _terminalNotifications.stream;

  /// Routes a private OSC sequence exactly as the live terminal does. Exposed so
  /// tests can exercise the OSC dispatch without a real shell channel.
  @visibleForTesting
  void debugHandlePrivateOsc(String code, List<String> args) =>
      _handlePrivateOsc(code, args);

  /// The terminal-output coalescing interval. Exposed so tests can hold
  /// buffered output deterministically instead of racing the real timer.
  @visibleForTesting
  Duration get debugTerminalOutputFlushInterval =>
      _runtime.debugTerminalOutputFlushInterval;

  @visibleForTesting
  set debugTerminalOutputFlushInterval(Duration value) =>
      _runtime.debugTerminalOutputFlushInterval = value;

  /// Synchronously flushes buffered terminal/stdout output. Exposed so tests can
  /// trigger a coalesced flush without waiting on the real coalescing timer.
  @visibleForTesting
  void debugFlushPendingTerminalOutput() =>
      _runtime.debugFlushPendingTerminalOutput();

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
  }) => _runtime.updateTerminalWindowMetrics(
    columns: columns,
    rows: rows,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
  );

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

  /// Updates the active terminal theme.
  ///
  /// Returns `true` when the theme changed enough to repaint previews.
  bool setTerminalTheme(TerminalThemeData? theme) {
    if (_sameTerminalTheme(_terminalTheme, theme)) {
      _terminalTheme = theme;
      return false;
    }
    _terminalTheme = theme;
    _notifyPreviewChanged();
    return true;
  }

  /// Ensure a [Terminal] exists and is wired to the shell streams.
  Terminal getOrCreateTerminal({int maxLines = 10000}) =>
      _runtime.getOrCreateTerminal(maxLines: maxLines);

  /// Active port forward tunnels.
  final Map<int, _ActiveTunnel> _activeTunnels = {};

  /// Get active tunnel info for display.
  List<ActiveTunnelInfo> get activeTunnels => _activeTunnels.entries
      .map(
        (e) => ActiveTunnelInfo(
          portForwardId: e.key,
          localHost: e.value.localHost,
          localPort: e.value.localPort,
          browserHost: e.value.browserHost,
          browserPort: e.value.browserPort,
          remoteHost: e.value.remoteHost,
          remotePort: e.value.remotePort,
          isLocal: e.value.isLocal,
        ),
      )
      .toList();

  /// Get or create a shell session.
  ///
  /// When [command] is provided for a new shell, the foreground PTY runs that
  /// command directly instead of opening an interactive login shell first. If
  /// [returnToLoginShell] is true, completing that command replaces its channel
  /// with an interactive login shell without closing the SSH connection.
  Future<SSHSession> getShell({
    SSHPtyConfig? pty,
    bool forceNew = false,
    String? command,
    bool returnToLoginShell = false,
  }) => _runtime.getShell(
    pty: pty,
    forceNew: forceNew,
    command: command,
    returnToLoginShell: returnToLoginShell,
  );

  /// Shell stdout as a broadcast stream for screen re-attachment.
  Stream<String> get shellStdoutStream => _runtime.shellStdoutStream;

  /// Shell stderr as a broadcast stream for screen re-attachment.
  Stream<String> get shellStderrStream => _runtime.shellStderrStream;

  /// Shell done event stream for screen re-attachment.
  Stream<void> get shellDoneStream => _runtime.shellDoneStream;

  /// Writes text to the currently active shell channel.
  void writeToShell(String data) => _runtime.writeToShell(data);

  /// Resizes the currently active shell channel.
  void resizeShell(int width, int height, int pixelWidth, int pixelHeight) =>
      _runtime.resizeShell(width, height, pixelWidth, pixelHeight);

  /// Close only the interactive shell channel while keeping the SSH client.
  Future<void> closeShell({bool waitForStreams = true}) =>
      _runtime.closeShell(waitForStreams: waitForStreams);

  void _resetShellRuntimeMetadata() {
    terminalHyperlinkTracker.reset(keepTerminalReference: false);
    _iconName = null;
    _workingDirectory = null;
    _shellStatus = null;
    _lastExitCode = null;
    _terminalPreview = null;
    _terminalPreviewSnapshot = null;
    _windowTitle = null;
    _lastVolunteeredThemeDefaultsAt = null;
  }

  DateTime? _lastVolunteeredThemeDefaultsAt;

  /// A color interrogation arrives as a burst of palette queries; volunteer
  /// the default foreground/background reports once per burst rather than
  /// once per query.
  static const _volunteeredThemeDefaultsWindow = Duration(seconds: 1);

  bool _shouldVolunteerThemeDefaults() {
    final now = DateTime.now();
    final last = _lastVolunteeredThemeDefaultsAt;
    if (last != null &&
        now.difference(last) < _volunteeredThemeDefaultsWindow) {
      return false;
    }
    _lastVolunteeredThemeDefaultsAt = now;
    return true;
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
          'hasShell': _runtime.hasShell,
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
      final shell = _runtime.shell;
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
        final win32InputMode = _runtime.terminalWin32InputMode;
        var payload = themeOscResponse;
        final volunteersThemeDefaults =
            win32InputMode && code == '4' && _shouldVolunteerThemeDefaults();
        if (volunteersThemeDefaults) {
          // Windows ConPTY consumes OSC 10/11 queries without forwarding or
          // answering them, so an app interrogating terminal colors (visible
          // through its OSC 4 palette queries, which do pass through) never
          // learns the default foreground/background. Volunteer those reports
          // alongside the palette answer while the app is parsing replies.
          payload += buildTerminalThemeDefaultColorReports(terminalTheme!);
        }
        if (win32InputMode) {
          // ConPTY strips raw OSC replies from the input stream; re-encode
          // them as win32-input-mode key events so they reach the app.
          payload = encodeTerminalResponsesForWin32InputMode(payload);
        }
        shell.write(utf8.encode(payload));
        DiagnosticsLogService.instance.debug(
          'terminal.osc',
          'theme_query_answered',
          fields: {
            'connectionId': connectionId,
            'code': code,
            'themeId': terminalTheme!.id,
            'responseBytes': payload.length,
            'win32InputMode': win32InputMode,
            'volunteeredThemeDefaults': volunteersThemeDefaults,
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

    if (code == '9' || code == '99' || code == '777') {
      _handleTerminalNotificationOsc(code, args);
      return;
    }

    _logUnhandledPrivateOsc(code, args);
  }

  void _handleTerminalNotificationOsc(String code, List<String> args) {
    final request = _terminalNotificationParser.handleOsc(code, args);
    if (request == null || _terminalNotifications.isClosed) {
      return;
    }
    _terminalNotifications.add(request);
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
            if (response != null) {
              _runtime.writeToShell(response);
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

  /// Builds a plain-text preview from the latest terminal display rows.
  static String? buildTerminalPreview(
    Terminal terminal, {
    int maxLines = _previewLineCount,
    int maxChars = _previewMaxChars,
  }) {
    final effectiveMaxLines = maxLines < 1 ? 1 : maxLines;
    final effectiveMaxChars = maxChars < 1 ? 1 : maxChars;
    final previewLines = <String>[];

    for (
      var index = terminal.lines.length - 1;
      index >= 0 && previewLines.length < effectiveMaxLines;
      index--
    ) {
      final rawLine = terminal.lines[index].getText();
      final cleanedLine = _sanitizePreviewFragment(rawLine);

      if (cleanedLine.isEmpty) {
        continue;
      }

      previewLines.insert(0, cleanedLine);
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

  /// Builds a styled preview from the latest terminal display rows.
  static TerminalPreviewSnapshot? buildTerminalPreviewSnapshot(
    Terminal terminal, {
    int maxLines = _previewLineCount,
  }) {
    final effectiveMaxLines = maxLines < 1 ? 1 : maxLines;
    final previewLines = <TerminalPreviewLine>[];
    final visibleRange = _terminalVisiblePreviewRange(
      terminal,
      effectiveMaxLines,
    );
    if (visibleRange == null) {
      return null;
    }

    for (var index = visibleRange.start; index <= visibleRange.end; index++) {
      final sourceLine = terminal.lines[index];
      final rawLine = sourceLine.getText();
      final cleanedLine = _sanitizePreviewFragment(rawLine);

      final cells = BufferLine(
        sourceLine.length,
        isWrapped: sourceLine.isWrapped,
      )..copyFrom(sourceLine, 0, 0, sourceLine.length);
      previewLines.add(TerminalPreviewLine(text: cleanedLine, cells: cells));
    }

    if (previewLines.isEmpty) {
      return null;
    }

    return TerminalPreviewSnapshot(
      lines: List.unmodifiable(previewLines),
      plainText: previewLines.map((line) => line.text).join('\n'),
      images: buildTerminalPreviewImages(
        terminal,
        startRow: visibleRange.start,
        endRow: visibleRange.end,
      ),
    );
  }

  static ({int start, int end})? _terminalVisiblePreviewRange(
    Terminal terminal,
    int maxLines,
  ) {
    final lineCount = terminal.lines.length;
    if (lineCount == 0) {
      return null;
    }
    final visibleStart = math.max(
      0,
      terminal.buffer.height - terminal.viewHeight,
    );
    final visibleEnd = terminal.buffer.height - 1;
    var lastNonEmpty = -1;
    for (var index = visibleEnd; index >= visibleStart; index--) {
      final cleanedLine = _sanitizePreviewFragment(
        terminal.lines[index].getText(),
      );
      if (cleanedLine.isNotEmpty) {
        lastNonEmpty = index;
        break;
      }
    }

    if (lastNonEmpty < 0) {
      return null;
    }
    return (
      start: math.max(visibleStart, lastNonEmpty - maxLines + 1),
      end: lastNonEmpty,
    );
  }

  static String _sanitizePreviewFragment(String text) =>
      text.replaceAll(_previewSanitizerPattern, '').trimRight();

  static String? _sanitizeWindowTitle(String text) {
    final sanitized = text.replaceAll(_windowTitleSanitizerPattern, '').trim();
    return sanitized.isEmpty ? null : sanitized;
  }

  static bool _sameTerminalTheme(
    TerminalThemeData? previous,
    TerminalThemeData? next,
  ) {
    if (previous == null || next == null) {
      return previous == next;
    }
    return terminalThemesMatchForColors(previous, next);
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
      _reportConnectionHealthFailureIfClosed(error, operation: 'exec');
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
  Future<SftpClient> sftp() async {
    final cachedSftp = _sftpClient;
    if (cachedSftp != null) {
      DiagnosticsLogService.instance.debug(
        'ssh.sftp',
        'reuse_client',
        fields: {'connectionId': connectionId, 'hostId': hostId},
      );
      return cachedSftp;
    }

    final inFlight = _sftpClientFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _openSftpClient();
    _sftpClientFuture = future;
    try {
      final sftpClient = await future;
      if (identical(_sftpClientFuture, future)) {
        _sftpClient = sftpClient;
      }
      return sftpClient;
    } finally {
      if (identical(_sftpClientFuture, future)) {
        _sftpClientFuture = null;
      }
    }
  }

  /// Open a one-off SFTP client without using the session cache.
  ///
  /// Prefer [sftp] for normal app SFTP work. This exists for flows that must
  /// bypass an in-flight shared SFTP open, such as a prompt-capable MonkeyMux
  /// install superseding a probe-only install.
  Future<SftpClient> openStandaloneSftp() => _openSftpClient();

  /// Discard the cached SFTP client for this session.
  ///
  /// Use this only when an SFTP operation timed out or failed in a way that may
  /// have left pending requests behind. Normal consumers should leave the
  /// session-owned client open so future SFTP work can reuse the same channel.
  void discardSftpClient(SftpClient? sftpClient) {
    final cachedSftp = _sftpClient;
    if (sftpClient != null) {
      if (cachedSftp == null) {
        sftpClient.close();
        return;
      }
      if (!identical(sftpClient, cachedSftp)) {
        return;
      }
    }
    _sftpClient = null;
    _sftpClientFuture = null;
    cachedSftp?.close();
  }

  Future<SftpClient> _openSftpClient() async {
    DiagnosticsLogService.instance.info(
      'ssh.sftp',
      'open_start',
      fields: {'connectionId': connectionId, 'hostId': hostId},
    );

    for (var attempt = 0; ; attempt += 1) {
      try {
        final sftpClient = await client.sftp();
        DiagnosticsLogService.instance.info(
          'ssh.sftp',
          'open_success',
          fields: {
            'connectionId': connectionId,
            'hostId': hostId,
            'attempt': attempt + 1,
          },
        );
        return sftpClient;
      } on Object catch (error) {
        final retryDelay = _sftpOpenRetryDelay(error, attempt);
        if (retryDelay != null) {
          DiagnosticsLogService.instance.warning(
            'ssh.sftp',
            'open_retry',
            fields: {
              'connectionId': connectionId,
              'hostId': hostId,
              'attempt': attempt + 1,
              'delayMs': retryDelay.inMilliseconds,
              ..._diagnosticSshExecErrorFields(error),
            },
          );
          await Future<void>.delayed(retryDelay);
          continue;
        }

        DiagnosticsLogService.instance.error(
          'ssh.sftp',
          'open_failed',
          fields: {
            'connectionId': connectionId,
            'hostId': hostId,
            'attempt': attempt + 1,
            ..._diagnosticSshExecErrorFields(error),
          },
        );
        _reportConnectionHealthFailureIfClosed(error, operation: 'sftp');
        rethrow;
      }
    }
  }

  Duration? _sftpOpenRetryDelay(Object error, int attempt) {
    if (attempt >= _sftpOpenRetryDelays.length ||
        !_isTransientSftpOpenError(error)) {
      return null;
    }
    return _sftpOpenRetryDelays[attempt];
  }

  bool _isTransientSftpOpenError(Object error) {
    if (error is! SSHChannelOpenError) {
      return false;
    }
    return error.code == 2 || error.code == 4;
  }

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

    ServerSocket? serverSocket;
    final browserServerSockets = <ServerSocket>[];
    try {
      final primaryServerSocket = await ServerSocket.bind(localHost, localPort);
      serverSocket = primaryServerSocket;
      final browserHost = portForwardBrowserHostForPortForwardId(portForwardId);
      final browserAddresses = [
        InternetAddress.loopbackIPv4,
        InternetAddress.loopbackIPv6,
      ];
      for (final address in browserAddresses) {
        if (_listenerSupportsPortForwardBrowserAddress(
          primaryServerSocket,
          address,
        )) {
          continue;
        }
        final browserServerSocket = await _bindPortForwardBrowserListener(
          address: address,
          port: primaryServerSocket.port,
          portForwardId: portForwardId,
        );
        if (browserServerSocket != null) {
          browserServerSockets.add(browserServerSocket);
        }
      }
      final hasBrowserEndpoint =
          browserAddresses.any(
            (address) => _listenerSupportsPortForwardBrowserAddress(
              primaryServerSocket,
              address,
            ),
          ) ||
          browserServerSockets.isNotEmpty;
      final tunnel = _ActiveTunnel.local(
        serverSocket: primaryServerSocket,
        browserServerSockets: browserServerSockets,
        browserHost: hasBrowserEndpoint ? browserHost : null,
        browserPort: hasBrowserEndpoint ? primaryServerSocket.port : null,
        localHost: localHost,
        localPort: primaryServerSocket.port,
        remoteHost: remoteHost,
        remotePort: remotePort,
      );

      _activeTunnels[portForwardId] = tunnel;

      tunnel.subscription = _listenToLocalForwardConnections(
        primaryServerSocket,
        remoteHost: remoteHost,
        remotePort: remotePort,
      );
      for (final browserServerSocket in browserServerSockets) {
        tunnel.browserSubscriptions.add(
          _listenToLocalForwardConnections(
            browserServerSocket,
            remoteHost: remoteHost,
            remotePort: remotePort,
          ),
        );
      }

      return true;
    } on Exception catch (e) {
      _activeTunnels.remove(portForwardId);
      for (final browserServerSocket in browserServerSockets) {
        await browserServerSocket.close();
      }
      await serverSocket?.close();
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

  bool _listenerSupportsPortForwardBrowserAddress(
    ServerSocket serverSocket,
    InternetAddress browserAddress,
  ) {
    final address = serverSocket.address;
    final wildcardAddress = switch (browserAddress.type) {
      InternetAddressType.IPv4 => InternetAddress.anyIPv4,
      InternetAddressType.IPv6 => InternetAddress.anyIPv6,
      _ => null,
    };
    return address.type == browserAddress.type &&
        (address.address == browserAddress.address ||
            address.address == wildcardAddress?.address);
  }

  Future<ServerSocket?> _bindPortForwardBrowserListener({
    required InternetAddress address,
    required int port,
    required int portForwardId,
  }) async {
    try {
      return await ServerSocket.bind(
        address,
        port,
        v6Only: address.type == InternetAddressType.IPv6,
      );
    } on SocketException catch (error) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'browser_listener_failed',
        fields: {
          'connectionId': connectionId,
          'hostId': hostId,
          'portForwardId': portForwardId,
          'addressFamily': address.type.name,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  StreamSubscription<Socket> _listenToLocalForwardConnections(
    ServerSocket serverSocket, {
    required String remoteHost,
    required int remotePort,
  }) => serverSocket.listen((socket) async {
    SSHForwardChannel? forward;
    try {
      forward = await client.forwardLocal(remoteHost, remotePort);
      final forwardToSocket = forward.stream.cast<List<int>>().pipe(socket);
      final socketToForward = socket.cast<List<int>>().pipe(forward.sink);

      await Future.any<void>([forwardToSocket, socketToForward]);
    } on SSHError catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'local_connection_failed',
        fields: {
          'connectionId': connectionId,
          'hostId': hostId,
          ..._diagnosticSshExecErrorFields(e),
        },
      );
      _reportConnectionHealthFailureIfClosed(e, operation: 'forward_local');
      if (kDebugMode) {
        debugPrint('Port forward connection error: $e');
      }
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
        localHost: localHost,
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
    } on SSHError catch (e) {
      DiagnosticsLogService.instance.warning(
        'ssh.forward',
        'remote_start_failed',
        fields: {
          'connectionId': connectionId,
          'hostId': hostId,
          ..._diagnosticSshExecErrorFields(e),
        },
      );
      _reportConnectionHealthFailureIfClosed(e, operation: 'forward_remote');
      if (kDebugMode) {
        debugPrint('Failed to start remote forward: $e');
      }
      return false;
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
      for (final browserSubscription in tunnel.browserSubscriptions) {
        await browserSubscription.cancel();
      }
      await tunnel.serverSocket?.close();
      for (final browserServerSocket in tunnel.browserServerSockets) {
        await browserServerSocket.close();
      }
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
  }) async {
    try {
      return await client.forwardLocal(remoteHost, remotePort);
    } on SSHError catch (e) {
      _reportConnectionHealthFailureIfClosed(e, operation: 'forward_local');
      rethrow;
    }
  }

  /// Close the session.
  Future<void> close() async {
    await stopAllForwards();
    await closeShell();
    discardSftpClient(null);
    await _connectionHealthFailures.close();
    await _terminalNotifications.close();
    client.close();
    for (final dependentClient in dependentClients) {
      dependentClient.close();
    }
  }

  void _reportConnectionHealthFailureIfClosed(
    Object error, {
    required String operation,
  }) {
    final reason = _diagnosticClosedSshConnectionErrorReason(error);
    if (reason == null ||
        _connectionHealthFailureReported ||
        _connectionHealthFailures.isClosed) {
      return;
    }
    _connectionHealthFailureReported = true;
    DiagnosticsLogService.instance.warning(
      'ssh.session',
      'stale_connection_detected',
      fields: {
        'connectionId': connectionId,
        'hostId': hostId,
        'operation': operation,
        'reason': reason,
        'errorType': error.runtimeType,
      },
    );
    _connectionHealthFailures.add(
      _SshConnectionHealthFailure(
        connectionId: connectionId,
        message: 'Connection became unresponsive. Reconnect to continue.',
      ),
    );
  }
}

/// Whether [session] is backed by MonkeySSH's in-app App Review demo transport.
bool isAppReviewDemoSession(SshSession session) =>
    session.client is _AppReviewDemoSshClient;

/// Writes synthetic remote output into the App Review demo terminal, if active.
void writeAppReviewDemoTerminalOutput(
  SshSession session,
  String text, {
  bool replaceScreen = false,
  bool showPrompt = true,
}) {
  if (!isAppReviewDemoSession(session)) {
    return;
  }
  final shell = session._runtime.shell;
  if (shell is _AppReviewDemoSshSession) {
    shell.writeDemoOutput(
      text,
      replaceScreen: replaceScreen,
      showPrompt: showPrompt,
    );
  }
}

class _SshConnectionHealthFailure {
  const _SshConnectionHealthFailure({
    required this.connectionId,
    required this.message,
  });

  final int connectionId;
  final String message;
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
    this.previewSnapshot,
    this.terminalTheme,
    this.sessionTitle,
    this.windowTitle,
    this.iconName,
    this.workingDirectory,
    this.shellStatus,
    this.lastExitCode,
    this.remoteMuxBackend,
    this.remoteMuxSessionName,
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

  /// The latest styled terminal preview snippet, when available.
  final TerminalPreviewSnapshot? previewSnapshot;

  /// The active terminal theme resolved for this connection.
  final TerminalThemeData? terminalTheme;

  /// The active coding-agent session title, when available.
  final String? sessionTitle;

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

  /// The terminal multiplexer backend attached in this connection, if known.
  final RemoteMuxBackend? remoteMuxBackend;

  /// The terminal multiplexer session attached in this connection, if known.
  final String? remoteMuxSessionName;

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
    required this.localHost,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.isLocal,
    this.browserHost,
    this.browserPort,
  });

  /// The port forward database ID.
  final int portForwardId;

  /// The local host configured for the tunnel.
  final String localHost;

  /// The local port being listened on.
  final int localPort;

  /// Browser-only loopback host that isolates this tunnel's cookies.
  final String? browserHost;

  /// Port exposed through the browser-only loopback host.
  final int? browserPort;

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
    required this.browserServerSockets,
    required this.browserHost,
    required this.browserPort,
    required this.localHost,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
  }) : remoteForward = null,
       isLocal = true;

  _ActiveTunnel.remote({
    required this.remoteForward,
    required this.localHost,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
  }) : serverSocket = null,
       browserServerSockets = const [],
       browserHost = null,
       browserPort = null,
       isLocal = false;

  final ServerSocket? serverSocket;
  final List<ServerSocket> browserServerSockets;
  final SSHRemoteForward? remoteForward;
  final String localHost;
  final int localPort;
  final String? browserHost;
  final int? browserPort;
  final String remoteHost;
  final int remotePort;
  final bool isLocal;
  // Cancelled in SshSession.stopForward().
  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? subscription;
  final List<StreamSubscription<dynamic>> browserSubscriptions = [];
}

class _AppReviewDemoSshClient implements SSHClient {
  _AppReviewDemoSshClient(this.host);

  final Host host;
  final _done = Completer<void>();
  bool _isClosed = false;
  _AppReviewDemoSftpClient? _sftp;

  @override
  String? get remoteVersion => 'SSH-2.0-MonkeySSH_App_Review_Demo';

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
  }) async => _AppReviewDemoSshSession.interactive(host);

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    if (pty != null && _looksLikeLoginShellCommand(command)) {
      return _AppReviewDemoSshSession.interactive(host);
    }
    return _AppReviewDemoSshSession.completed(_demoExecOutput(command));
  }

  @override
  Future<SftpClient> sftp() async => _sftp ??= _AppReviewDemoSftpClient();

  @override
  Future<SSHForwardChannel> forwardLocal(
    String remoteHost,
    int remotePort, {
    String localHost = 'localhost',
    int localPort = 0,
  }) async => _AppReviewDemoForwardChannel(
    remoteHost: remoteHost,
    remotePort: remotePort,
  );

  @override
  Future<SSHRemoteForward?> forwardRemote({
    String? host,
    int? port,
    SSHRemoteConnectionFilter? filter,
  }) async => null;

  @override
  Future<Uint8List> run(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async => Uint8List.fromList(utf8.encode(_demoExecOutput(command)));

  @override
  Future<SSHRunResult> runWithResult(
    String command, {
    bool runInPty = false,
    bool stdout = true,
    bool stderr = true,
    Map<String, String>? environment,
  }) async {
    final output = Uint8List.fromList(utf8.encode(_demoExecOutput(command)));
    return SSHRunResult(
      output: output,
      stdout: stdout ? output : Uint8List(0),
      stderr: Uint8List(0),
      exitCode: 0,
      exitSignal: null,
    );
  }

  @override
  void close() {
    if (_isClosed) {
      return;
    }
    _isClosed = true;
    _sftp?.close();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  static bool _looksLikeLoginShellCommand(String command) =>
      command.contains('COLORTERM=truecolor') ||
      command.contains('TERM_PROGRAM=kitty') ||
      command.contains('/bin/sh -lc');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppReviewDemoSshSession implements SSHSession {
  _AppReviewDemoSshSession._({required this.exitCode})
    : _stdinController = StreamController<Uint8List>(),
      _stdoutController = StreamController<Uint8List>(),
      _stderrController = StreamController<Uint8List>() {
    _stdinSubscription = _stdinController.stream.listen(_handleInput);
  }

  factory _AppReviewDemoSshSession.interactive(Host host) {
    final session = _AppReviewDemoSshSession._(exitCode: null);
    scheduleMicrotask(() {
      session
        .._writeText(_demoInteractiveBanner(host))
        .._writePrompt();
    });
    return session;
  }

  factory _AppReviewDemoSshSession.completed(String stdout) {
    final session = _AppReviewDemoSshSession._(exitCode: 0);
    scheduleMicrotask(() async {
      if (stdout.isNotEmpty) {
        session._writeText(stdout);
      }
      await session._finish(exitCode: 0);
    });
    return session;
  }

  @override
  final int? exitCode;

  @override
  SSHSessionExitSignal? get exitSignal => null;

  late final StreamSubscription<Uint8List> _stdinSubscription;
  final StreamController<Uint8List> _stdinController;
  final StreamController<Uint8List> _stdoutController;
  final StreamController<Uint8List> _stderrController;
  final _done = Completer<void>();
  final _exitCompleter = Completer<int?>();
  final _input = StringBuffer();
  bool _closed = false;

  @override
  StreamSink<Uint8List> get stdin => _stdinController.sink;

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) {
    if (!_closed) {
      _handleInput(data);
    }
  }

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {}

  @override
  void close() {
    unawaited(_finish(exitCode: exitCode));
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
    _writeText('^C\r\n');
    close();
  }

  void _handleInput(Uint8List data) {
    if (_closed) {
      return;
    }
    final text = utf8.decode(data, allowMalformed: true);
    for (var i = 0; i < text.length; i += 1) {
      final codeUnit = text.codeUnitAt(i);
      if (codeUnit == 0x03) {
        _input.clear();
        _writeText('^C\r\n');
        _writePrompt();
        continue;
      }
      if (codeUnit == 0x04) {
        close();
        continue;
      }
      if (codeUnit == 0x7F || codeUnit == 0x08) {
        final current = _input.toString();
        if (current.isNotEmpty) {
          _input
            ..clear()
            ..write(current.substring(0, current.length - 1));
          _writeText('\b \b');
        }
        continue;
      }
      if (codeUnit == 0x0D || codeUnit == 0x0A) {
        final command = _input.toString().trim();
        _input.clear();
        _writeText('\r\n');
        _runInteractiveCommand(command);
        if (!_closed) {
          _writePrompt();
        }
        continue;
      }
      if (codeUnit == 0x1B) {
        continue;
      }
      final char = String.fromCharCode(codeUnit);
      _input.write(char);
      _writeText(char);
    }
  }

  void _runInteractiveCommand(String command) {
    if (command.isEmpty) {
      return;
    }
    final normalized = command.toLowerCase();
    if (normalized == 'clear') {
      _writeText('\x1b[2J\x1b[H');
      return;
    }
    if (normalized == 'exit' || normalized == 'logout') {
      _writeText('logout\r\n');
      close();
      return;
    }
    _writeText(_demoInteractiveCommandOutput(command));
  }

  void _writePrompt() {
    _writeText(r'reviewer@demo:~/demo$ ');
  }

  void _writeText(String text) {
    if (_closed || _stdoutController.isClosed) {
      return;
    }
    _stdoutController.add(
      Uint8List.fromList(utf8.encode(_normalizeDemoTerminalOutput(text))),
    );
  }

  void writeDemoOutput(
    String text, {
    bool replaceScreen = false,
    bool showPrompt = true,
  }) {
    if (_closed) {
      return;
    }
    if (replaceScreen) {
      _writeText('\x1b[2J\x1b[H$text');
    } else {
      _writeText('\r\n$text');
    }
    if (showPrompt && !text.endsWith('\n') && !text.endsWith('\r')) {
      _writeText('\r\n');
    }
    if (showPrompt) {
      _writePrompt();
    }
  }

  Future<void> _finish({int? exitCode}) async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _stdinSubscription.cancel();
    await _stdinController.close();
    await _stdoutController.close();
    await _stderrController.close();
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(exitCode);
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppReviewDemoSftpClient implements SftpClient {
  _AppReviewDemoSftpClient();

  static const _home = '/home/reviewer';
  static const _workspace = '/home/reviewer/work/monkeyssh-demo';
  final _files = Map<String, String>.from(_demoSftpFiles);
  bool _closed = false;

  @override
  Future<SftpHandsake> get handshake =>
      Future<SftpHandsake>.value(SftpHandsake(3, const {}));

  @override
  Future<String> absolute(String path) async => _normalizeDemoSftpPath(path);

  @override
  Future<List<SftpName>> listdir(String path) async {
    final directory = _normalizeDemoSftpPath(path);
    final entries = <SftpName>[];
    for (final child in _demoSftpDirectoryChildren(directory)) {
      final childPath = _joinDemoSftpPath(directory, child);
      final isDirectory = _demoSftpDirectories.contains(childPath);
      entries.add(
        SftpName(
          filename: child,
          longname: child,
          attr: isDirectory
              ? _demoDirectoryAttrs()
              : _demoFileAttrs(_files[childPath]?.length ?? 0),
        ),
      );
    }
    return entries;
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    final normalized = _normalizeDemoSftpPath(path);
    if (_demoSftpDirectories.contains(normalized)) {
      return _demoDirectoryAttrs();
    }
    final content = _files[normalized];
    if (content != null) {
      return _demoFileAttrs(content.length);
    }
    throw StateError('No such file: $path');
  }

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async {
    final normalized = _normalizeDemoSftpPath(path);
    _files.putIfAbsent(normalized, () => '');
    return _AppReviewDemoSftpFile(
      attrs: _demoFileAttrs(_files[normalized]!.length),
      readContent: () => _files[normalized] ?? '',
      writeContent: (value) => _files[normalized] = value,
    );
  }

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {}

  @override
  Future<void> rmdir(String dirname) async {}

  @override
  Future<void> remove(String filename) async {
    _files.remove(_normalizeDemoSftpPath(filename));
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final oldNormalized = _normalizeDemoSftpPath(oldPath);
    final content = _files.remove(oldNormalized);
    if (content != null) {
      _files[_normalizeDemoSftpPath(newPath)] = content;
    }
  }

  @override
  void close() {
    _closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (_closed) {
      throw StateError('Connection closed');
    }
    return super.noSuchMethod(invocation);
  }
}

class _AppReviewDemoSftpFile implements SftpFile {
  _AppReviewDemoSftpFile({
    required SftpFileAttrs attrs,
    required String Function() readContent,
    required void Function(String value) writeContent,
  }) : _attrs = attrs,
       _readContent = readContent,
       _writeContent = writeContent;

  final String Function() _readContent;
  final void Function(String value) _writeContent;
  SftpFileAttrs _attrs;
  bool _isClosed = false;

  @override
  bool get isClosed => _isClosed;

  @override
  Future<SftpFileAttrs> stat() async => _attrs;

  @override
  Stream<Uint8List> read({
    int? length,
    int offset = 0,
    void Function(int bytesRead)? onProgress,
    int chunkSize = 16 * 1024,
    int maxPendingRequests = 64,
  }) async* {
    final bytes = Uint8List.fromList(utf8.encode(_readContent()));
    final start = offset.clamp(0, bytes.length);
    final requestedLength = length ?? bytes.length - start;
    final end = (start + requestedLength).clamp(start, bytes.length);
    final chunk = Uint8List.sublistView(bytes, start, end);
    if (chunk.isNotEmpty) {
      onProgress?.call(chunk.length);
      yield chunk;
    }
  }

  @override
  Future<Uint8List> readBytes({int? length, int offset = 0}) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in read(length: length, offset: offset)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    final text = utf8.decode(data, allowMalformed: true);
    _writeContent(text);
    _attrs = _demoFileAttrs(text.length);
  }

  @override
  Future<void> close() async {
    _isClosed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppReviewDemoForwardChannel implements SSHForwardChannel {
  _AppReviewDemoForwardChannel({
    required String remoteHost,
    required int remotePort,
  }) : _response = _demoForwardHttpResponse(remoteHost, remotePort) {
    _sinkController.stream.drain<void>().ignore();
    scheduleMicrotask(() async {
      _streamController.add(Uint8List.fromList(utf8.encode(_response)));
      await close();
    });
  }

  final String _response;
  final _streamController = StreamController<Uint8List>();
  final _sinkController = StreamController<List<int>>();
  final _done = Completer<void>();
  bool _closed = false;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  @override
  StreamSink<List<int>> get sink => _sinkController.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _sinkController.close();
    await _streamController.close();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  void destroy() {
    unawaited(close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _demoSftpDirectories = <String>{
  '/',
  '/home',
  '/home/reviewer',
  '/home/reviewer/work',
  '/home/reviewer/work/monkeyssh-demo',
  '/home/reviewer/work/monkeyssh-demo/logs',
  '/home/reviewer/work/monkeyssh-demo/src',
  '/home/reviewer/work/monkeyssh-demo/screenshots',
};

const _demoSftpFiles = <String, String>{
  '/home/reviewer/work/monkeyssh-demo/README.md': '''
# MonkeySSH App Review Demo

This is an in-app local demo workspace. It does not require a private SSH
server, but it behaves like a connected terminal for review.
''',
  '/home/reviewer/work/monkeyssh-demo/package.json': '''
{"scripts":{"dev":"vite --host 127.0.0.1","test":"flutter test"}}
''',
  '/home/reviewer/work/monkeyssh-demo/deploy-demo.sh': '''
#!/bin/sh
echo "dry-run deploy complete"
''',
  '/home/reviewer/work/monkeyssh-demo/logs/app.log': '''
01:08:22 connected local review shell
01:08:23 loaded MonkeyMux workspace metadata
01:08:24 opened sample SFTP tree
''',
  '/home/reviewer/work/monkeyssh-demo/src/main.dart': '''
void main() {
  print('MonkeySSH App Review Demo');
}
''',
};

String _demoInteractiveBanner(Host host) =>
    '''
\x1b]0;${host.label}\x07\x1b]7;file://localhost/home/reviewer/work/monkeyssh-demo\x07MonkeySSH App Review Demo

Connected locally for:
  ${_shortDemoHostLabel(host.label)}

No external SSH server or credentials are required.

Sample workspace: ~/work/monkeyssh-demo

Try:
  ls
  pwd
  cat README.md
  monkeymux windows
  copilot

''';

String _shortDemoHostLabel(String label) =>
    label.replaceFirst('${AppReviewDemoService.demoHostLabelPrefix} ', '');

String _normalizeDemoTerminalOutput(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');

String _demoInteractiveCommandOutput(String command) {
  final normalized = command.toLowerCase();
  if (normalized == 'pwd') {
    return '/home/reviewer/work/monkeyssh-demo\r\n';
  }
  if (normalized == 'whoami') {
    return 'reviewer\r\n';
  }
  if (normalized == 'ls' || normalized == 'ls -la') {
    return 'README.md  deploy-demo.sh  logs  package.json  screenshots  src\r\n';
  }
  if (normalized == 'cat readme.md' ||
      normalized == 'cat README.md'.toLowerCase()) {
    return '${_demoSftpFiles['/home/reviewer/work/monkeyssh-demo/README.md']}\r\n';
  }
  if (normalized.contains('monkeymux') || normalized.contains('tmux')) {
    return '''
review-workspace
  0  Copilot CLI     planning App Review notes
  1  Claude Code    running focused tests
  2  OpenCode       editing README.md
  3  SFTP           browsing /home/reviewer/work/monkeyssh-demo
''';
  }
  if (normalized.contains('copilot')) {
    return '''
Copilot CLI demo
  ✓ inspected staged changes
  ✓ prepared review notes
  → ready for /deploy
''';
  }
  if (normalized.contains('deploy-demo')) {
    return 'dry-run deploy complete\r\n';
  }
  return 'demo shell: command "$command" completed locally\r\n';
}

String _demoExecOutput(String command) {
  final normalized = command.toLowerCase();
  if (normalized.contains('pwd')) {
    return '/home/reviewer/work/monkeyssh-demo\n';
  }
  if (normalized.contains('tmux') && normalized.contains('list')) {
    return 'review-workspace: 4 windows\n';
  }
  if (normalized.contains('command -v') ||
      normalized.contains('which ') ||
      normalized.contains('uname')) {
    return '';
  }
  return '';
}

String _demoForwardHttpResponse(String remoteHost, int remotePort) {
  const body = '''
<!doctype html>
<title>MonkeySSH App Review Demo</title>
<h1>MonkeySSH forwarded preview</h1>
<p>This page was served by the in-app demo tunnel.</p>
''';
  return 'HTTP/1.1 200 OK\r\n'
      'content-type: text/html; charset=utf-8\r\n'
      'content-length: ${utf8.encode(body).length}\r\n'
      'connection: close\r\n'
      '\r\n'
      '$body';
}

List<String> _demoSftpDirectoryChildren(String directory) {
  final children = <String>{};
  for (final path in [..._demoSftpDirectories, ..._demoSftpFiles.keys]) {
    if (path == directory || !path.startsWith('$directory/')) {
      continue;
    }
    final remainder = path.substring(
      directory == '/' ? 1 : directory.length + 1,
    );
    if (remainder.isEmpty || remainder.contains('/')) {
      continue;
    }
    children.add(remainder);
  }
  return children.toList()..sort();
}

String _normalizeDemoSftpPath(String input) {
  var path = input.trim();
  if (path.isEmpty || path == '.') {
    return _AppReviewDemoSftpClient._workspace;
  }
  if (path == '~') {
    return _AppReviewDemoSftpClient._home;
  }
  if (path.startsWith('~/')) {
    path = '${_AppReviewDemoSftpClient._home}/${path.substring(2)}';
  }
  if (!path.startsWith('/')) {
    path = '${_AppReviewDemoSftpClient._workspace}/$path';
  }
  while (path.contains('//')) {
    path = path.replaceAll('//', '/');
  }
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

String _joinDemoSftpPath(String directory, String child) =>
    directory == '/' ? '/$child' : '$directory/$child';

SftpFileAttrs _demoDirectoryAttrs() => SftpFileAttrs(
  size: 0,
  mode: const SftpFileMode.value(0x4000 | 0x01ED),
  modifyTime: 1783325486,
);

SftpFileAttrs _demoFileAttrs(int size) => SftpFileAttrs(
  size: size,
  mode: const SftpFileMode.value(0x8000 | 0x01A4),
  modifyTime: 1783325486,
);

String _telemetryAuthMethodFromHost(Host? host) {
  if (host == null) {
    return 'unknown';
  }
  final hasPassword = host.password?.isNotEmpty ?? false;
  final hasKey = host.keyId != null;
  if (hasPassword && hasKey) {
    return 'password_and_key';
  }
  if (hasKey) {
    return 'key';
  }
  if (hasPassword) {
    return 'password';
  }
  return 'none';
}

String _telemetryConnectionFailureCategory(String? error) {
  final normalized = error?.toLowerCase() ?? '';
  if (normalized.contains('auth') ||
      normalized.contains('password') ||
      normalized.contains('key') ||
      normalized.contains('credential')) {
    return 'authentication';
  }
  if (normalized.contains('timeout') || normalized.contains('timed out')) {
    return 'timeout';
  }
  if (normalized.contains('host key')) {
    return 'host_key';
  }
  if (normalized.contains('network') ||
      normalized.contains('socket') ||
      normalized.contains('connection refused') ||
      normalized.contains('unreachable')) {
    return 'network';
  }
  if (normalized.contains('setup')) {
    return 'setup';
  }
  return 'unknown';
}

/// Provider for [SshService].
final sshServiceProvider = Provider<SshService>(
  (ref) => SshService(
    hostRepository: ref.watch(hostRepositoryProvider),
    keyRepository: ref.watch(keyRepositoryProvider),
    knownHostsRepository: ref.watch(knownHostsRepositoryProvider),
    hostKeyPromptHandler: ref.watch(hostKeyPromptHandlerProvider),
    interactiveAuthPromptHandler: ref.watch(
      interactiveAuthPromptHandlerProvider,
    ),
    wifiNetworkService: ref.watch(wifiNetworkServiceProvider),
  ),
);

/// Provider for tracking active SSH sessions.
final activeSessionsProvider =
    NotifierProvider<ActiveSessionsNotifier, Map<int, SshConnectionState>>(
      ActiveSessionsNotifier.new,
    );

/// Provider for host-level connection attempt progress.
final connectionAttemptProvider =
    Provider.family<ConnectionAttemptStatus?, int>((ref, hostId) {
      ref.watch(activeSessionsProvider);
      return ref
          .read(activeSessionsProvider.notifier)
          .getConnectionAttempt(hostId);
    });

/// Notifier for active SSH sessions state.
class ActiveSessionsNotifier extends Notifier<Map<int, SshConnectionState>> {
  static const _previewStateRefreshInterval = Duration(milliseconds: 150);

  late final SshService _sshService;
  final Map<int, int> _connectionHostIds = {};
  final Map<int, String> _connectionSessionTitles = {};
  final Map<int, ConnectionAttemptStatus> _connectionAttempts = {};
  final Map<int, StreamSubscription<void>> _disconnectSubscriptions = {};
  final Map<int, StreamSubscription<_SshConnectionHealthFailure>>
  _connectionHealthFailureSubscriptions = {};
  final Map<int, StreamSubscription<TerminalNotificationRequest>>
  _terminalNotificationSubscriptions = {};
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
      for (final subscription in _connectionHealthFailureSubscriptions.values) {
        unawaited(subscription.cancel());
      }
      _connectionHealthFailureSubscriptions.clear();
      for (final subscription in _terminalNotificationSubscriptions.values) {
        unawaited(subscription.cancel());
      }
      _terminalNotificationSubscriptions.clear();
    });
    _connectionHostIds.clear();
    _connectionSessionTitles.clear();
    _connectionAttempts.clear();
    return {};
  }

  /// Connect to a host.
  Future<SshConnectionResult> connect(
    int hostId, {
    bool forceNew = false,
    bool useHostThemeOverrides = true,
  }) async {
    final telemetry = ref.read(telemetryServiceProvider);
    if (!forceNew) {
      final existingConnectionId = getPreferredConnectionForHost(hostId);
      if (existingConnectionId != null) {
        DiagnosticsLogService.instance.info(
          'ssh.active',
          'reuse_connection',
          fields: {'hostId': hostId, 'connectionId': existingConnectionId},
        );
        unawaited(_queueBackgroundStatusSync());
        unawaited(
          telemetry.logTerminalSessionStarted(
            reusedConnection: true,
            usedBackgroundService: false,
          ),
        );
        return SshConnectionResult(
          success: true,
          connectionId: existingConnectionId,
          reusedConnection: true,
        );
      }
    }

    final host = await _telemetryHostForConnection(hostId);
    final startedAt = DateTime.now();
    unawaited(
      telemetry.logConnectionAttempted(
        authMethod: _telemetryAuthMethodFromHost(host),
        usesJumpHost: host?.jumpHostId != null,
      ),
    );
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
      unawaited(
        telemetry.logConnectionSucceeded(
          authMethod: _telemetryAuthMethodFromHost(host),
          usesJumpHost: host?.jumpHostId != null,
          duration: DateTime.now().difference(startedAt),
        ),
      );
      unawaited(
        telemetry.logTerminalSessionStarted(
          reusedConnection: false,
          usedBackgroundService: false,
        ),
      );
    } else {
      _updateConnectionAttempt(
        hostId,
        ConnectionProgressUpdate(
          state: SshConnectionState.error,
          message: result.error ?? 'Connection failed',
        ),
      );
      unawaited(
        telemetry.logConnectionFailed(
          authMethod: _telemetryAuthMethodFromHost(host),
          usesJumpHost: host?.jumpHostId != null,
          duration: DateTime.now().difference(startedAt),
          failureCategory: _telemetryConnectionFailureCategory(result.error),
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
    final session = _sshService.getSession(connectionId);
    DiagnosticsLogService.instance.info(
      'ssh.active',
      'disconnect',
      fields: {'connectionId': connectionId},
    );
    _detachSessionListeners(connectionId);
    if (session != null) {
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logTerminalSessionEnded(
              duration: DateTime.now().difference(session.createdAt),
              disconnectCategory: 'user',
              usedBackgroundService: false,
            ),
      );
    }
    await _sshService.disconnect(connectionId);
    _connectionHostIds.remove(connectionId);
    _connectionSessionTitles.remove(connectionId);
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
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logTerminalSessionEnded(
              duration: DateTime.now().difference(session.createdAt),
              disconnectCategory: 'disconnect_all',
              usedBackgroundService: false,
            ),
      );
    }
    await _sshService.disconnectAll();
    _connectionHostIds.clear();
    _connectionSessionTitles.clear();
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
      previewSnapshot: session.terminalPreviewSnapshot,
      terminalTheme: session.terminalTheme,
      sessionTitle: _connectionSessionTitles[connectionId],
      windowTitle: session.windowTitle,
      iconName: session.iconName,
      workingDirectory: session.workingDirectory,
      shellStatus: session.shellStatus,
      lastExitCode: session.lastExitCode,
      remoteMuxBackend: session.remoteMuxBackend,
      remoteMuxSessionName: session.remoteMuxSessionName,
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

  /// Get the newest active connection that already owns a local forward.
  int? getConnectionForActiveLocalForward(int portForwardId) {
    final activeConnections = <SshSession>[];
    for (final session in _sshService.sessions.values) {
      final connectionState = state[session.connectionId];
      if (connectionState == null ||
          connectionState == SshConnectionState.error ||
          connectionState == SshConnectionState.disconnected) {
        continue;
      }

      final hasLocalForward = session.activeTunnels.any(
        (tunnel) => tunnel.portForwardId == portForwardId && tunnel.isLocal,
      );
      if (hasLocalForward) {
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
          previewSnapshot: session.terminalPreviewSnapshot,
          terminalTheme: session.terminalTheme,
          sessionTitle: _connectionSessionTitles[connectionId],
          windowTitle: session.windowTitle,
          iconName: session.iconName,
          workingDirectory: session.workingDirectory,
          shellStatus: session.shellStatus,
          lastExitCode: session.lastExitCode,
          remoteMuxBackend: session.remoteMuxBackend,
          remoteMuxSessionName: session.remoteMuxSessionName,
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
    final existingHealthFailureSubscription =
        _connectionHealthFailureSubscriptions.remove(session.connectionId);
    if (existingHealthFailureSubscription != null) {
      unawaited(existingHealthFailureSubscription.cancel());
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
    _connectionHealthFailureSubscriptions[session.connectionId] = session
        ._connectionHealthFailureStream
        .listen(
          (failure) => unawaited(
            handleUnexpectedDisconnect(
              failure.connectionId,
              message: failure.message,
            ),
          ),
        );
    final existingNotificationSubscription = _terminalNotificationSubscriptions
        .remove(session.connectionId);
    if (existingNotificationSubscription != null) {
      unawaited(existingNotificationSubscription.cancel());
    }
    _terminalNotificationSubscriptions[session.connectionId] = session
        .terminalNotifications
        .listen(
          (request) => unawaited(_showTerminalNotification(session, request)),
        );
  }

  Future<void> _showTerminalNotification(
    SshSession session,
    TerminalNotificationRequest request,
  ) async {
    if (!ref.mounted) return;
    if (!ref.read(terminalNotificationsNotifierProvider)) return;
    final title = request.title ?? await _resolveSessionLabel(session);
    if (!ref.mounted) return;
    await ref
        .read(localNotificationServiceProvider)
        .showTerminalNotification(
          notificationId: _terminalNotificationId(session.connectionId),
          title: title,
          body: request.body,
          payload: TerminalNotificationPayload(
            hostId: session.hostId,
            connectionId: session.connectionId,
          ),
        );
  }

  Future<String> _resolveSessionLabel(SshSession session) async {
    final windowTitle = session.windowTitle;
    if (windowTitle != null && windowTitle.trim().isNotEmpty) {
      return windowTitle.trim();
    }
    try {
      final host = await ref
          .read(hostRepositoryProvider)
          .getById(session.hostId);
      if (host != null && host.label.trim().isNotEmpty) {
        return host.label.trim();
      }
    } on Object {
      // Fall through to the generic label below.
    }
    return 'Terminal';
  }

  int _terminalNotificationId(int connectionId) =>
      Object.hash('terminal-notification', connectionId) & 0x7fffffff;

  void _detachSessionListeners(int connectionId, {SshSession? session}) {
    (session ?? _sshService.getSession(connectionId))?.removePreviewListener(
      _schedulePreviewStateRefresh,
    );
    final subscription = _disconnectSubscriptions.remove(connectionId);
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    final healthFailureSubscription = _connectionHealthFailureSubscriptions
        .remove(connectionId);
    if (healthFailureSubscription != null) {
      unawaited(healthFailureSubscription.cancel());
    }
    final notificationSubscription = _terminalNotificationSubscriptions.remove(
      connectionId,
    );
    if (notificationSubscription != null) {
      unawaited(notificationSubscription.cancel());
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

  /// Update the active coding-agent session title attached to a connection.
  void updateConnectionSessionTitle(int connectionId, String? sessionTitle) {
    final normalizedTitle = _normalizeConnectionSessionTitle(sessionTitle);
    final currentTitle = _connectionSessionTitles[connectionId];
    if (normalizedTitle == currentTitle ||
        (normalizedTitle == null && currentTitle == null)) {
      return;
    }
    if (normalizedTitle == null) {
      _connectionSessionTitles.remove(connectionId);
    } else {
      _connectionSessionTitles[connectionId] = normalizedTitle;
    }
    state = {...state};
  }

  String? _normalizeConnectionSessionTitle(String? sessionTitle) {
    final trimmed = sessionTitle?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<Host?> _telemetryHostForConnection(int hostId) async {
    try {
      return await ref.read(hostRepositoryProvider).getById(hostId);
    } on Object {
      return null;
    }
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
    if (session != null) {
      unawaited(
        ref
            .read(telemetryServiceProvider)
            .logTerminalSessionEnded(
              duration: DateTime.now().difference(session.createdAt),
              disconnectCategory: 'unexpected',
              usedBackgroundService: false,
            ),
      );
    }
    await _sshService.disconnect(connectionId);
    _connectionHostIds.remove(connectionId);
    _connectionSessionTitles.remove(connectionId);
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
