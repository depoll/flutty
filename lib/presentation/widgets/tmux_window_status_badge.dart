import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/models/tmux_state.dart';

/// Consistent terminal-native title text for a remote multiplexer window.
///
/// Selection changes weight only; the font family and size remain stable so a
/// title never jumps when its window becomes active.
class TmuxWindowTitleText extends StatelessWidget {
  /// Creates a remote-window title.
  const TmuxWindowTitleText({
    required this.title,
    required this.isActive,
    this.fontSize = 13,
    super.key,
  });

  /// Window title text.
  final String title;

  /// Whether the window is currently active.
  final bool isActive;

  /// Title size shared by active and inactive states.
  final double fontSize;

  @override
  Widget build(BuildContext context) => Text(
    title,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: FluttyTheme.monoStyle.copyWith(
      fontSize: fontSize,
      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
      color: Theme.of(context).colorScheme.onSurface,
      height: 1.2,
    ),
  );
}

/// Compact status badge for a tmux window.
class TmuxWindowStatusBadge extends StatefulWidget {
  /// Creates a new [TmuxWindowStatusBadge].
  const TmuxWindowStatusBadge({required this.window, super.key});

  /// The tmux window whose status is being displayed.
  final TmuxWindow window;

  @override
  State<TmuxWindowStatusBadge> createState() => _TmuxWindowStatusBadgeState();

  static _TmuxWindowStatusVisual _statusVisual(
    ThemeData theme,
    TmuxWindow window,
  ) {
    if (window.hasAlert) {
      return _TmuxWindowStatusVisual(
        icon: Icons.notifications_active,
        foregroundColor: theme.colorScheme.onErrorContainer,
        backgroundColor: theme.colorScheme.errorContainer,
      );
    }
    if (window.isIdle) {
      return _TmuxWindowStatusVisual(
        icon: Icons.hourglass_bottom,
        foregroundColor: theme.colorScheme.onTertiaryContainer,
        backgroundColor: theme.colorScheme.tertiaryContainer,
      );
    }
    return _TmuxWindowStatusVisual(
      icon: Icons.play_arrow,
      foregroundColor: theme.colorScheme.onPrimaryContainer,
      backgroundColor: theme.colorScheme.primaryContainer,
    );
  }
}

class _TmuxWindowStatusBadgeState extends State<TmuxWindowStatusBadge> {
  Timer? _idleRefreshTimer;

  @override
  void initState() {
    super.initState();
    _updateIdleRefreshTimer();
  }

  @override
  void didUpdateWidget(covariant TmuxWindowStatusBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.window == widget.window) return;
    _updateIdleRefreshTimer();
  }

  @override
  void dispose() {
    _idleRefreshTimer?.cancel();
    super.dispose();
  }

  void _updateIdleRefreshTimer() {
    _idleRefreshTimer?.cancel();
    if (!widget.window.needsLocalIdleRefresh) {
      _idleRefreshTimer = null;
      return;
    }
    _idleRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!widget.window.needsLocalIdleRefresh) {
        _idleRefreshTimer?.cancel();
        _idleRefreshTimer = null;
      }
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visual = TmuxWindowStatusBadge._statusVisual(theme, widget.window);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: visual.backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(visual.icon, size: 12, color: visual.foregroundColor),
            const SizedBox(width: 3),
            Text(
              widget.window.statusLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10,
                color: visual.foregroundColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TmuxWindowStatusVisual {
  const _TmuxWindowStatusVisual({
    required this.icon,
    required this.foregroundColor,
    required this.backgroundColor,
  });

  final IconData icon;
  final Color foregroundColor;
  final Color backgroundColor;
}
