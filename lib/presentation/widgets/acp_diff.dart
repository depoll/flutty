import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../models/acp_timeline.dart';

enum _DiffLineKind { addition, deletion, hunk, meta, context }

/// Renders a unified diff as coloured, monospace lines.
///
/// Additions and deletions are conveyed with both a `+`/`-` prefix and a
/// background tint (never colour alone), avoiding nested cards and coloured
/// side stripes per the design system. Long lines scroll horizontally.
class AcpDiffView extends StatelessWidget {
  /// Creates a diff view.
  const AcpDiffView({
    required this.diff,
    super.key,
    this.showPathHeader = true,
  });

  /// The diff to render.
  final AcpDiff diff;

  /// Whether to show the file path header above the diff body.
  final bool showPathHeader;

  static _DiffLineKind _classify(String line) {
    if (line.startsWith('@@')) {
      return _DiffLineKind.hunk;
    }
    if (line.startsWith('+++') ||
        line.startsWith('---') ||
        line.startsWith('diff ') ||
        line.startsWith('index ')) {
      return _DiffLineKind.meta;
    }
    if (line.startsWith('+')) {
      return _DiffLineKind.addition;
    }
    if (line.startsWith('-')) {
      return _DiffLineKind.deletion;
    }
    return _DiffLineKind.context;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final additionColor = isDark
        ? const Color(0xFF3FB950)
        : const Color(0xFF1A7F37);
    final deletionColor = scheme.error;
    final monoBase = FluttyTheme.monoStyle.copyWith(fontSize: 12, height: 1.4);

    final lines = diff.unifiedDiff.split('\n');
    final rows = <Widget>[];
    for (final line in lines) {
      final kind = _classify(line);
      final Color? background;
      final Color color;
      switch (kind) {
        case _DiffLineKind.addition:
          background = additionColor.withValues(alpha: 0.14);
          color = additionColor;
        case _DiffLineKind.deletion:
          background = deletionColor.withValues(alpha: 0.14);
          color = deletionColor;
        case _DiffLineKind.hunk:
          background = null;
          color = scheme.primary;
        case _DiffLineKind.meta:
          background = null;
          color = scheme.onSurfaceVariant;
        case _DiffLineKind.context:
          background = null;
          color = scheme.onSurface;
      }
      rows.add(
        Container(
          color: background,
          padding: const EdgeInsets.symmetric(
            horizontal: FluttyTheme.spacingSm,
            vertical: 1,
          ),
          child: Text(
            line.isEmpty ? ' ' : line,
            style: monoBase.copyWith(color: color),
          ),
        ),
      );
    }

    return Semantics(
      label: 'Diff for ${diff.path}',
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          border: Border.all(color: scheme.outline),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(FluttyTheme.radiusSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showPathHeader)
                Container(
                  width: double.infinity,
                  color: scheme.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(
                    horizontal: FluttyTheme.spacingSm,
                    vertical: 6,
                  ),
                  child: Text(
                    diff.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FluttyTheme.monoStyle.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: IntrinsicWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: rows,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
