final _trailingTerminalPaddingPattern = RegExp(r' +$');

/// Trims terminal cell padding from the end of a rendered line.
String trimTerminalLinePadding(String line) =>
    line.replaceFirst(_trailingTerminalPaddingPattern, '');

/// Trims per-line terminal padding from copied or selected terminal text.
String trimTerminalSelectionText(String text) =>
    text.split('\n').map(trimTerminalLinePadding).join('\n');
