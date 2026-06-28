import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'cursor_block.dart';

/// A title in the mono display voice, trailed by the blinking [CursorBlock]
/// brand mark.
///
/// The title and cursor are baseline-aligned so the cursor sits on the text
/// baseline like a real terminal cursor. Used for top-level surface titles so
/// every primary surface announces itself the same terminal-native way.
class MonoHeaderTitle extends StatelessWidget {
  /// Creates a [MonoHeaderTitle].
  const MonoHeaderTitle(this.title, {this.fontSize = 20, super.key});

  /// The title text, e.g. `hosts`.
  final String title;

  /// Display font size.
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: title,
            style: FluttyTheme.displayMono(
              fontSize: fontSize,
              color: colorScheme.onSurface,
            ),
          ),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Padding(
              padding: const EdgeInsets.only(left: 5),
              child: CursorBlock(size: fontSize, color: colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}
