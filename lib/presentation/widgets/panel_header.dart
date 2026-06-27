import 'package:flutter/material.dart';

import 'mono_header_title.dart';

/// A consistent header bar for a top-level panel (Hosts, Connections, Keys,
/// Snippets).
///
/// Renders a [MonoHeaderTitle] on the left and optional trailing [actions] on
/// the right, at a fixed [height] so switching between panels — some with
/// action buttons, some without — never shifts the header.
class PanelHeader extends StatelessWidget {
  /// Creates a [PanelHeader].
  const PanelHeader({required this.title, this.actions = const [], super.key});

  /// The panel title, e.g. `hosts`.
  final String title;

  /// Trailing, right-aligned action widgets (e.g. buttons).
  final List<Widget> actions;

  /// The fixed height shared by every panel header.
  static const double height = 56;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: height,
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colorScheme.outline.withAlpha(60)),
        ),
      ),
      child: Row(
        children: [MonoHeaderTitle(title), const Spacer(), ...actions],
      ),
    );
  }
}
