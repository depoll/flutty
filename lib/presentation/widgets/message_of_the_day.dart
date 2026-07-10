import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'cursor_block.dart';

/// A small, dry message-of-the-day rendered as a faux shell prompt.
///
/// This is one of the few sanctioned places the brand's restrained,
/// terminal-native wit is allowed to show — a reward for looking closely, in
/// the margins (the About screen), never on a surface the user reaches under
/// pressure. The line is stable for a given calendar day and rotates day to
/// day, so it stays fresh without being random on every rebuild.
class MessageOfTheDay extends StatelessWidget {
  /// Creates a [MessageOfTheDay].
  ///
  /// [date] overrides "today" for deterministic tests; it defaults to the
  /// current date.
  const MessageOfTheDay({this.date, super.key});

  /// The date used to pick the line. Defaults to [DateTime.now].
  final DateTime? date;

  /// The pool of dry, terminal-native lines. Kept true to the product and
  /// safe to show anywhere — the voice of a good CLI, never a punchline.
  static const List<String> messages = <String>[
    'remote work, taken literally.',
    'your agents kept working while you were away.',
    'the cursor blinks, therefore it is.',
    'reconnected in seconds, like you never left.',
    'no laptop in sight.',
    'your sessions kept your seat.',
    'ssh somewhere nice today.',
    'fewer tabs, more terminals.',
  ];

  /// The line shown for [date] (or today): stable per calendar day.
  String get message {
    final today = date ?? DateTime.now();
    final dayNumber = DateTime(
      today.year,
      today.month,
      today.day,
    ).difference(DateTime(today.year)).inDays;
    return messages[dayNumber % messages.length];
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final promptStyle = FluttyTheme.monoStyle.copyWith(
      fontSize: 12,
      color: colorScheme.onSurfaceVariant,
    );
    final messageStyle = FluttyTheme.monoStyle.copyWith(
      fontSize: 12,
      color: colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FluttyTheme.spacingMd,
        FluttyTheme.spacingSm,
        FluttyTheme.spacingMd,
        FluttyTheme.spacingMd,
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: r'$ ', style: promptStyle),
            TextSpan(text: message, style: messageStyle),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: CursorBlock(size: 13, color: colorScheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
