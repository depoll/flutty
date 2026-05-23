import 'package:flutter/material.dart';

/// Shared visual styling for terminal menus.
class TerminalMenuStyles {
  const TerminalMenuStyles._();

  /// Screen-edge margin used when positioning terminal menus.
  static const screenMargin = 8.0;

  /// Gap between a menu and an adjacent cascading menu.
  static const cascadeGap = 8.0;

  /// Height of each terminal menu row.
  static const itemHeight = 44.0;

  /// Width of terminal menu leading and trailing icons.
  static const iconSize = 20.0;

  /// Horizontal padding for terminal menu rows.
  static const itemHorizontalPadding = 14.0;

  /// Gap between a terminal menu icon and its label.
  static const iconLabelGap = 12.0;

  /// Elevation shared by terminal menu surfaces.
  static const elevation = 8.0;

  /// Radius shared by terminal menu surfaces.
  static const borderRadius = 12.0;

  /// Returns the shared terminal menu surface color.
  static Color surfaceColor(BuildContext context) =>
      Theme.of(context).colorScheme.surfaceContainerHighest;

  /// Returns the shared terminal menu text style.
  static TextStyle itemTextStyle(
    BuildContext context, {
    bool emphasized = false,
  }) {
    final baseStyle =
        Theme.of(context).textTheme.labelLarge ?? const TextStyle(fontSize: 14);
    return baseStyle.copyWith(
      fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
    );
  }

  /// Returns the shared terminal menu style for [MenuAnchor] menus.
  static MenuStyle menuStyle(
    BuildContext context, {
    Size? minimumSize,
    Size? maximumSize,
  }) => MenuStyle(
    backgroundColor: WidgetStatePropertyAll<Color>(surfaceColor(context)),
    elevation: const WidgetStatePropertyAll<double>(elevation),
    shadowColor: WidgetStatePropertyAll<Color>(Theme.of(context).shadowColor),
    shape: WidgetStatePropertyAll<OutlinedBorder>(_shape),
    padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.zero),
    minimumSize: minimumSize == null
        ? null
        : WidgetStatePropertyAll<Size>(minimumSize),
    maximumSize: maximumSize == null
        ? null
        : WidgetStatePropertyAll<Size>(maximumSize),
  );

  /// Returns the shared terminal menu button style.
  static ButtonStyle itemButtonStyle(BuildContext context) => ButtonStyle(
    minimumSize: const WidgetStatePropertyAll<Size>(Size(0, itemHeight)),
    padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
      EdgeInsets.symmetric(horizontal: itemHorizontalPadding),
    ),
    foregroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
      final colorScheme = Theme.of(context).colorScheme;
      if (states.contains(WidgetState.disabled)) {
        return colorScheme.onSurfaceVariant.withAlpha(96);
      }
      return colorScheme.onSurfaceVariant;
    }),
    iconSize: const WidgetStatePropertyAll<double>(iconSize),
    textStyle: WidgetStatePropertyAll<TextStyle?>(itemTextStyle(context)),
  );

  /// Wraps custom menu content in the shared terminal menu surface.
  static Widget surface(BuildContext context, {required Widget child}) =>
      Material(
        color: surfaceColor(context),
        elevation: elevation,
        shadowColor: Theme.of(context).shadowColor,
        shape: _shape,
        clipBehavior: Clip.antiAlias,
        child: child,
      );

  static final _shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(borderRadius),
  );
}
