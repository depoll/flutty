import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

const _terminalReadableContrastRatio = 4.5;

double _contrastRatio(Color a, Color b) {
  final luminanceA = a.computeLuminance();
  final luminanceB = b.computeLuminance();
  final brightest = math.max(luminanceA, luminanceB);
  final darkest = math.min(luminanceA, luminanceB);
  return (brightest + 0.05) / (darkest + 0.05);
}

double _minimumContrastRatio(Color color, List<Color> backgrounds) {
  var minimumRatio = double.infinity;
  for (final background in backgrounds) {
    minimumRatio = math.min(minimumRatio, _contrastRatio(color, background));
  }
  return minimumRatio;
}

double _colorDistance(Color a, Color b) {
  final argbA = a.toARGB32();
  final argbB = b.toARGB32();
  final redDelta = ((argbA >> 16) & 0xFF) - ((argbB >> 16) & 0xFF);
  final greenDelta = ((argbA >> 8) & 0xFF) - ((argbB >> 8) & 0xFF);
  final blueDelta = (argbA & 0xFF) - (argbB & 0xFF);
  return (redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta)
      .toDouble();
}

Color _opaqueGray(int channel) =>
    Color.fromARGB(0xFF, channel, channel, channel);

Color _ensureContrast(
  Color color, {
  required Iterable<Color> against,
  required double minRatio,
}) {
  final backgrounds = List<Color>.unmodifiable(against);
  if (backgrounds.isEmpty ||
      _minimumContrastRatio(color, backgrounds) >= minRatio) {
    return color;
  }

  var bestPassingCandidate = color;
  var bestPassingDistance = double.infinity;
  var fallbackCandidate = color;
  var fallbackRatio = _minimumContrastRatio(color, backgrounds);
  var fallbackDistance = 0.0;

  void considerCandidate(Color candidate) {
    final minimumRatio = _minimumContrastRatio(candidate, backgrounds);
    final distance = _colorDistance(color, candidate);
    if (minimumRatio >= minRatio && distance < bestPassingDistance) {
      bestPassingCandidate = candidate;
      bestPassingDistance = distance;
    }
    if (minimumRatio > fallbackRatio ||
        (minimumRatio == fallbackRatio && distance < fallbackDistance)) {
      fallbackCandidate = candidate;
      fallbackRatio = minimumRatio;
      fallbackDistance = distance;
    }
  }

  for (final target in const <Color>[Colors.white, Colors.black]) {
    for (var step = 1; step <= 200; step++) {
      final candidate = Color.lerp(color, target, step / 200);
      if (candidate == null) {
        continue;
      }
      considerCandidate(candidate);
      if (bestPassingDistance.isFinite) {
        break;
      }
    }
  }

  for (var channel = 0; channel <= 255; channel++) {
    considerCandidate(_opaqueGray(channel));
  }

  return bestPassingDistance.isFinite
      ? bestPassingCandidate
      : fallbackCandidate;
}

/// Data model for a terminal color theme.
///
/// Contains all 16 ANSI colors plus special colors for cursor, selection,
/// foreground, and background. Can be converted to xterm's [TerminalTheme].
@immutable
class TerminalThemeData {
  /// Creates a new [TerminalThemeData].
  const TerminalThemeData({
    required this.id,
    required this.name,
    required this.isDark,
    required this.foreground,
    required this.background,
    required this.cursor,
    required this.selection,
    required this.black,
    required this.red,
    required this.green,
    required this.yellow,
    required this.blue,
    required this.magenta,
    required this.cyan,
    required this.white,
    required this.brightBlack,
    required this.brightRed,
    required this.brightGreen,
    required this.brightYellow,
    required this.brightBlue,
    required this.brightMagenta,
    required this.brightCyan,
    required this.brightWhite,
    this.isCustom = false,
    this.searchHitBackground,
    this.searchHitBackgroundCurrent,
    this.searchHitForeground,
  });

  /// Creates a theme from a JSON map.
  factory TerminalThemeData.fromJson(Map<String, dynamic> json) =>
      TerminalThemeData(
        id: json['id'] as String,
        name: json['name'] as String,
        isDark: json['isDark'] as bool,
        isCustom: json['isCustom'] as bool? ?? true,
        foreground: Color(json['foreground'] as int),
        background: Color(json['background'] as int),
        cursor: Color(json['cursor'] as int),
        selection: Color(json['selection'] as int),
        black: Color(json['black'] as int),
        red: Color(json['red'] as int),
        green: Color(json['green'] as int),
        yellow: Color(json['yellow'] as int),
        blue: Color(json['blue'] as int),
        magenta: Color(json['magenta'] as int),
        cyan: Color(json['cyan'] as int),
        white: Color(json['white'] as int),
        brightBlack: Color(json['brightBlack'] as int),
        brightRed: Color(json['brightRed'] as int),
        brightGreen: Color(json['brightGreen'] as int),
        brightYellow: Color(json['brightYellow'] as int),
        brightBlue: Color(json['brightBlue'] as int),
        brightMagenta: Color(json['brightMagenta'] as int),
        brightCyan: Color(json['brightCyan'] as int),
        brightWhite: Color(json['brightWhite'] as int),
        searchHitBackground: json['searchHitBackground'] != null
            ? Color(json['searchHitBackground'] as int)
            : null,
        searchHitBackgroundCurrent: json['searchHitBackgroundCurrent'] != null
            ? Color(json['searchHitBackgroundCurrent'] as int)
            : null,
        searchHitForeground: json['searchHitForeground'] != null
            ? Color(json['searchHitForeground'] as int)
            : null,
      );

  /// Creates a theme from a JSON string.
  factory TerminalThemeData.fromJsonString(String jsonString) =>
      TerminalThemeData.fromJson(
        jsonDecode(jsonString) as Map<String, dynamic>,
      );

  /// Unique identifier for the theme.
  final String id;

  /// Display name of the theme.
  final String name;

  /// Whether this theme is designed for dark backgrounds.
  final bool isDark;

  /// Whether this is a user-created custom theme.
  final bool isCustom;

  /// Main text color.
  final Color foreground;

  /// Terminal background color.
  final Color background;

  /// Cursor color.
  final Color cursor;

  /// Selection highlight color.
  final Color selection;

  /// ANSI color 0 (black).
  final Color black;

  /// ANSI color 1 (red).
  final Color red;

  /// ANSI color 2 (green).
  final Color green;

  /// ANSI color 3 (yellow).
  final Color yellow;

  /// ANSI color 4 (blue).
  final Color blue;

  /// ANSI color 5 (magenta).
  final Color magenta;

  /// ANSI color 6 (cyan).
  final Color cyan;

  /// ANSI color 7 (white).
  final Color white;

  /// ANSI color 8 (bright black).
  final Color brightBlack;

  /// ANSI color 9 (bright red).
  final Color brightRed;

  /// ANSI color 10 (bright green).
  final Color brightGreen;

  /// ANSI color 11 (bright yellow).
  final Color brightYellow;

  /// ANSI color 12 (bright blue).
  final Color brightBlue;

  /// ANSI color 13 (bright magenta).
  final Color brightMagenta;

  /// ANSI color 14 (bright cyan).
  final Color brightCyan;

  /// ANSI color 15 (bright white).
  final Color brightWhite;

  /// Background color for search hits.
  final Color? searchHitBackground;

  /// Background color for current search hit.
  final Color? searchHitBackgroundCurrent;

  /// Foreground color for search hits.
  final Color? searchHitForeground;

  /// Converts this theme data to xterm's [TerminalTheme].
  TerminalTheme toXtermTheme() {
    final readableForeground = _ensureContrast(
      foreground,
      against: <Color>[background],
      minRatio: _terminalReadableContrastRatio,
    );
    final readableBrightBlack = _ensureContrast(
      brightBlack,
      against: <Color>[black],
      minRatio: _terminalReadableContrastRatio,
    );
    final readableWhite = _ensureContrast(
      white,
      against: <Color>[black],
      minRatio: _terminalReadableContrastRatio,
    );
    final readableBrightWhite = _ensureContrast(
      brightWhite,
      against: <Color>[black],
      minRatio: _terminalReadableContrastRatio,
    );
    final readableBlack = _ensureContrast(
      black,
      against: <Color>[green, yellow],
      minRatio: _terminalReadableContrastRatio,
    );
    return TerminalTheme(
      cursor: cursor,
      selection: selection,
      foreground: readableForeground,
      background: background,
      black: readableBlack,
      red: red,
      green: green,
      yellow: yellow,
      blue: blue,
      magenta: magenta,
      cyan: cyan,
      white: readableWhite,
      brightBlack: readableBrightBlack,
      brightRed: brightRed,
      brightGreen: brightGreen,
      brightYellow: brightYellow,
      brightBlue: brightBlue,
      brightMagenta: brightMagenta,
      brightCyan: brightCyan,
      brightWhite: readableBrightWhite,
      searchHitBackground: searchHitBackground ?? const Color(0xFFFFDF5D),
      searchHitBackgroundCurrent:
          searchHitBackgroundCurrent ?? const Color(0xFFFF9632),
      searchHitForeground: searchHitForeground ?? const Color(0xFF000000),
    );
  }

  /// Creates a copy of this theme with the given fields replaced.
  TerminalThemeData copyWith({
    String? id,
    String? name,
    bool? isDark,
    bool? isCustom,
    Color? foreground,
    Color? background,
    Color? cursor,
    Color? selection,
    Color? black,
    Color? red,
    Color? green,
    Color? yellow,
    Color? blue,
    Color? magenta,
    Color? cyan,
    Color? white,
    Color? brightBlack,
    Color? brightRed,
    Color? brightGreen,
    Color? brightYellow,
    Color? brightBlue,
    Color? brightMagenta,
    Color? brightCyan,
    Color? brightWhite,
    Color? searchHitBackground,
    Color? searchHitBackgroundCurrent,
    Color? searchHitForeground,
  }) => TerminalThemeData(
    id: id ?? this.id,
    name: name ?? this.name,
    isDark: isDark ?? this.isDark,
    isCustom: isCustom ?? this.isCustom,
    foreground: foreground ?? this.foreground,
    background: background ?? this.background,
    cursor: cursor ?? this.cursor,
    selection: selection ?? this.selection,
    black: black ?? this.black,
    red: red ?? this.red,
    green: green ?? this.green,
    yellow: yellow ?? this.yellow,
    blue: blue ?? this.blue,
    magenta: magenta ?? this.magenta,
    cyan: cyan ?? this.cyan,
    white: white ?? this.white,
    brightBlack: brightBlack ?? this.brightBlack,
    brightRed: brightRed ?? this.brightRed,
    brightGreen: brightGreen ?? this.brightGreen,
    brightYellow: brightYellow ?? this.brightYellow,
    brightBlue: brightBlue ?? this.brightBlue,
    brightMagenta: brightMagenta ?? this.brightMagenta,
    brightCyan: brightCyan ?? this.brightCyan,
    brightWhite: brightWhite ?? this.brightWhite,
    searchHitBackground: searchHitBackground ?? this.searchHitBackground,
    searchHitBackgroundCurrent:
        searchHitBackgroundCurrent ?? this.searchHitBackgroundCurrent,
    searchHitForeground: searchHitForeground ?? this.searchHitForeground,
  );

  /// Converts this theme to a JSON map for storage.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'isDark': isDark,
    'isCustom': isCustom,
    'foreground': foreground.toARGB32(),
    'background': background.toARGB32(),
    'cursor': cursor.toARGB32(),
    'selection': selection.toARGB32(),
    'black': black.toARGB32(),
    'red': red.toARGB32(),
    'green': green.toARGB32(),
    'yellow': yellow.toARGB32(),
    'blue': blue.toARGB32(),
    'magenta': magenta.toARGB32(),
    'cyan': cyan.toARGB32(),
    'white': white.toARGB32(),
    'brightBlack': brightBlack.toARGB32(),
    'brightRed': brightRed.toARGB32(),
    'brightGreen': brightGreen.toARGB32(),
    'brightYellow': brightYellow.toARGB32(),
    'brightBlue': brightBlue.toARGB32(),
    'brightMagenta': brightMagenta.toARGB32(),
    'brightCyan': brightCyan.toARGB32(),
    'brightWhite': brightWhite.toARGB32(),
    if (searchHitBackground != null)
      'searchHitBackground': searchHitBackground!.toARGB32(),
    if (searchHitBackgroundCurrent != null)
      'searchHitBackgroundCurrent': searchHitBackgroundCurrent!.toARGB32(),
    if (searchHitForeground != null)
      'searchHitForeground': searchHitForeground!.toARGB32(),
  };

  /// Serializes this theme to a JSON string.
  String toJsonString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalThemeData &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
