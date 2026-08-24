/// Pure, testable helpers for the ACP slash-command autocomplete experience.
///
/// These functions never touch Flutter or perform I/O. They decide when a
/// leading slash token is being typed, rank the dynamically advertised
/// [AcpAvailableCommand]s against that token, and compute the exact text and
/// caret position produced when a command is chosen. Keeping this logic
/// separate from the widget lets the trigger, matching, and insertion rules be
/// verified without pumping a widget tree.
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/acp_updates.dart';

/// An in-progress leading slash-command token.
@immutable
class AcpSlashQuery {
  /// Creates a slash query for the token text after the leading slash.
  const AcpSlashQuery(this.query);

  /// The characters typed after the leading `/`, excluding the slash itself.
  final String query;

  @override
  bool operator ==(Object other) =>
      other is AcpSlashQuery && other.query == query;

  @override
  int get hashCode => query.hashCode;

  @override
  String toString() => 'AcpSlashQuery($query)';
}

/// Detects whether [textBeforeCaret] is an active leading slash-command token.
///
/// A command token is only active when the text up to the caret begins with a
/// single `/` and contains no whitespace after it: as soon as the user types a
/// space (i.e. starts entering arguments) or the slash is not the leading
/// character, the autocomplete stops so an arbitrary `/` in prose (for example
/// a path or a fraction) is never reinterpreted as a command.
AcpSlashQuery? parseSlashQuery(String textBeforeCaret) {
  if (!textBeforeCaret.startsWith('/')) {
    return null;
  }
  final rest = textBeforeCaret.substring(1);
  if (rest.startsWith('/')) {
    // A doubled slash is not a command (e.g. a `//` comment or URL scheme).
    return null;
  }
  if (rest.contains(RegExp(r'\s'))) {
    return null;
  }
  return AcpSlashQuery(rest);
}

/// Ranks [commands] against [query], matching on name and description.
///
/// An empty query returns every command in its original order. Otherwise
/// results are ordered by match quality: exact name, name prefix, name
/// substring, then description substring. Matching is case-insensitive and
/// stable within a rank tier.
List<AcpAvailableCommand> matchSlashCommands(
  String query,
  List<AcpAvailableCommand> commands,
) {
  final normalized = query.toLowerCase();
  if (normalized.isEmpty) {
    return List<AcpAvailableCommand>.unmodifiable(commands);
  }

  final ranked = <({int rank, int index, AcpAvailableCommand command})>[];
  for (var i = 0; i < commands.length; i++) {
    final command = commands[i];
    final name = command.name.toLowerCase();
    final description = command.description.toLowerCase();
    int? rank;
    if (name == normalized) {
      rank = 0;
    } else if (name.startsWith(normalized)) {
      rank = 1;
    } else if (name.contains(normalized)) {
      rank = 2;
    } else if (description.contains(normalized)) {
      rank = 3;
    }
    if (rank != null) {
      ranked.add((rank: rank, index: i, command: command));
    }
  }

  ranked.sort((a, b) {
    final byRank = a.rank.compareTo(b.rank);
    return byRank != 0 ? byRank : a.index.compareTo(b.index);
  });

  return List<AcpAvailableCommand>.unmodifiable(
    ranked.map((entry) => entry.command),
  );
}

/// The text and caret position produced by choosing a slash command.
@immutable
class AcpSlashInsertion {
  /// Creates a slash insertion result.
  const AcpSlashInsertion({required this.text, required this.caret});

  /// The full composer text after the command is inserted.
  final String text;

  /// The caret offset within [text] after insertion.
  final int caret;

  @override
  bool operator ==(Object other) =>
      other is AcpSlashInsertion && other.text == text && other.caret == caret;

  @override
  int get hashCode => Object.hash(text, caret);

  @override
  String toString() => 'AcpSlashInsertion($text, $caret)';
}

/// Computes the composer text after inserting [command] for the leading token.
///
/// The leading `/token` in [fullText] is replaced with `/<name> ` so the caret
/// lands after a single separating space, ready for arguments. Any text that
/// already followed the token is preserved with exactly one separating space.
AcpSlashInsertion applySlashCommand({
  required String fullText,
  required AcpAvailableCommand command,
}) {
  final whitespace = fullText.indexOf(RegExp(r'\s'));
  final tokenEnd = whitespace >= 0 ? whitespace : fullText.length;
  final trailing = fullText.substring(tokenEnd).trimLeft();
  final prefix = '/${command.name} ';
  final text = '$prefix$trailing';
  return AcpSlashInsertion(text: text, caret: prefix.length);
}
