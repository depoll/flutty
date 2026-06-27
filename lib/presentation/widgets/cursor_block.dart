import 'dart:async';

import 'package:flutter/material.dart';

/// The MonkeySSH brand mark: a terminal cursor block (`▮`) that can blink.
///
/// Used as the signature motif across the app — trailing the wordmark, marking
/// active states, and anchoring loading and empty states. It blinks like a live
/// terminal cursor, and honors the platform "reduce motion" setting by rendering
/// static when animations are disabled.
///
/// The blink is driven by a [Timer] (a hard on/off toggle, like a real terminal
/// cursor) rather than a repeating animation, so it never blocks
/// `WidgetTester.pumpAndSettle` in tests.
class CursorBlock extends StatefulWidget {
  /// Creates a [CursorBlock].
  const CursorBlock({super.key, this.color, this.size, this.blinking = true});

  /// Glyph color. Defaults to the theme's primary (Signal Teal).
  final Color? color;

  /// Glyph size in logical pixels. Defaults to the ambient text size.
  final double? size;

  /// Whether the block blinks.
  ///
  /// Ignored when the platform requests reduced motion, in which case the block
  /// is always rendered static (fully visible).
  final bool blinking;

  @override
  State<CursorBlock> createState() => _CursorBlockState();
}

class _CursorBlockState extends State<CursorBlock> {
  Timer? _timer;
  bool _on = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void didUpdateWidget(CursorBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blinking != widget.blinking) {
      _syncTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final animate = widget.blinking && !reduceMotion;
    if (animate) {
      _timer ??= Timer.periodic(const Duration(milliseconds: 530), (_) {
        if (mounted) {
          setState(() => _on = !_on);
        }
      });
    } else {
      _timer?.cancel();
      _timer = null;
      _on = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return ExcludeSemantics(
      child: Opacity(
        opacity: _on ? 1 : 0,
        child: Text(
          '▮',
          style: TextStyle(color: color, fontSize: widget.size, height: 1),
        ),
      ),
    );
  }
}
