import 'dart:ui' show clampDouble;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, immutable, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../domain/models/terminal_theme.dart';
import '../domain/services/diagnostics_log_service.dart';

/// Theme configuration for the Flutty app.
/// Inspired by Termius with a modern hacker aesthetic.
abstract final class FluttyTheme {
  // Core palette - deep space with accents sampled from the app icon.
  static const _accentTeal = Color(0xFF14756C);
  static const _accentTealSoft = Color(0xFF58A38C);
  static const _backgroundDark = Color(0xFF0D0D12);
  static const _surfaceDark = Color(0xFF16161D);
  static const _cardDark = Color(0xFF1C1C26);
  static const _borderDark = Color(0xFF2A2A3A);
  static const _textPrimary = Color(0xFFF0F0F5);
  static const _textSecondary = Color(0xFF8A8A9A);
  static const _errorColor = Color(0xFFFF4757);
  static const _warningColor = Color(0xFFFFBE00);

  // Light theme equivalents
  static const _backgroundLight = Color(0xFFF8F9FC);
  static const _surfaceLight = Color(0xFFFFFFFF);
  static const _cardLight = Color(0xFFFFFFFF);
  static const _borderLight = Color(0xFFE8E8EF);

  /// Standard spacing constants for consistent layout.
  static const double spacingXs = 4;

  /// Small spacing.
  static const double spacingSm = 8;

  /// Medium spacing.
  static const double spacingMd = 16;

  /// Large spacing.
  static const double spacingLg = 24;

  /// Extra-large spacing.
  static const double spacingXl = 32;

  /// Standard border radius for cards and containers.
  static const double radiusSm = 8;

  /// Medium border radius.
  static const double radiusMd = 12;

  /// Large border radius.
  static const double radiusLg = 16;

  /// Standard icon size for empty states.
  static const double emptyStateIconSize = 48;

  /// Light theme.
  static ThemeData get light => _buildTheme(Brightness.light);

  /// Dark theme.
  static ThemeData get dark => _buildTheme(Brightness.dark);

  /// Uses system text styles instead of Google Fonts when true.
  ///
  /// This is intended for tests that instantiate theme data without a bundled
  /// font asset bundle.
  @visibleForTesting
  static bool debugUseSystemFonts = false;

  /// Builds an app theme using colors from a terminal theme palette.
  static ThemeData fromTerminalTheme(
    TerminalThemeData terminalTheme, {
    required Brightness brightness,
  }) => _buildTheme(brightness, terminalTheme: terminalTheme);

  static ThemeData _buildTheme(
    Brightness brightness, {
    TerminalThemeData? terminalTheme,
  }) {
    final isDark = brightness == Brightness.dark;
    final background =
        terminalTheme?.background ??
        (isDark ? _backgroundDark : _backgroundLight);
    final textPrimary =
        terminalTheme?.foreground ?? (isDark ? _textPrimary : Colors.black87);
    final textSecondary = terminalTheme == null
        ? (isDark ? _textSecondary : Colors.black54)
        : _blend(background, textPrimary, isDark ? 0.62 : 0.84);
    final surface =
        terminalTheme?.background ?? (isDark ? _surfaceDark : _surfaceLight);
    final card = terminalTheme == null
        ? (isDark ? _cardDark : _cardLight)
        : _blend(background, textPrimary, isDark ? 0.07 : 0.025);
    final border = terminalTheme == null
        ? (isDark ? _borderDark : _borderLight)
        : _blend(background, textPrimary, isDark ? 0.18 : 0.16);
    final primary = terminalTheme == null
        ? _accentTeal
        : _resolveTerminalAccent(terminalTheme);
    final primarySoft = terminalTheme == null
        ? _accentTealSoft
        : _blend(background, primary, isDark ? 0.55 : 0.28);
    final error = terminalTheme?.red ?? _errorColor;
    final warning = terminalTheme?.yellow ?? _warningColor;
    final inputFill = terminalTheme == null
        ? (isDark ? _cardDark : Colors.grey.shade50)
        : _blend(background, textPrimary, isDark ? 0.08 : 0.018);
    final inputHover = terminalTheme == null
        ? (isDark ? _borderDark : Colors.grey.shade100)
        : _blend(background, textPrimary, isDark ? 0.12 : 0.045);
    final overlayBackground = terminalTheme?.black ?? Colors.grey.shade900;
    final snackBarBackground = isDark ? card : overlayBackground;
    final snackBarForeground = _readableTextColor(snackBarBackground);
    final tooltipBackground = isDark ? card : overlayBackground;
    final tooltipForeground = _readableTextColor(tooltipBackground);
    final onPrimary = terminalTheme == null
        ? Colors.white
        : _readableTextColor(primary);
    final onTertiary = terminalTheme == null
        ? Colors.black
        : _readableTextColor(warning);
    final onError = terminalTheme == null
        ? Colors.white
        : _readableTextColor(error);

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: onPrimary,
      secondary: card,
      onSecondary: textPrimary,
      tertiary: warning,
      onTertiary: onTertiary,
      error: error,
      onError: onError,
      surface: surface,
      onSurface: textPrimary,
      surfaceContainerHighest: card,
      outline: border,
      outlineVariant: border.withAlpha(isDark ? 128 : 180),
    );

    // Use JetBrains Mono for that terminal feel, Inter for UI
    final baseTextTheme = isDark
        ? ThemeData.dark().textTheme
        : ThemeData.light().textTheme;

    final textTheme = _interTextTheme(baseTextTheme).copyWith(
      // Headings with more weight
      headlineLarge: _inter(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: textPrimary,
        letterSpacing: -0.5,
      ),
      headlineMedium: _inter(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: textPrimary,
        letterSpacing: -0.3,
      ),
      headlineSmall: _inter(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      titleLarge: _inter(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
      titleMedium: _inter(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: textPrimary,
      ),
      bodyLarge: _inter(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: textPrimary,
      ),
      bodyMedium: _inter(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: textSecondary,
      ),
      bodySmall: _inter(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: textSecondary,
      ),
      labelLarge: _inter(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: textPrimary,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: background,
      pageTransitionsTheme: _buildPageTransitionsTheme(background),

      // App bar with subtle blur effect vibe
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: _inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
      ),

      // Cards with subtle glow on dark theme
      cardTheme: CardThemeData(
        color: card,
        elevation: isDark ? 0 : 1,
        shadowColor: isDark ? primary.withAlpha(20) : Colors.black12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border),
        ),
        margin: EdgeInsets.zero,
      ),

      // Glowing FAB
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        elevation: isDark ? 8 : 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      // Modern input fields
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFill,
        hoverColor: inputHover,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: error),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        labelStyle: TextStyle(color: textSecondary),
        hintStyle: TextStyle(color: textSecondary.withAlpha(150)),
        prefixIconColor: textSecondary,
      ),

      // Buttons with glow
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: _inter(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: isDark ? 4 : 2,
          shadowColor: isDark ? primary.withAlpha(80) : Colors.black26,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: _inter(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          side: BorderSide(color: border, width: 1.5),
          textStyle: _inter(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          textStyle: _inter(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),

      // Segmented buttons
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return colorScheme.primary;
            }
            return card;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return colorScheme.onPrimary;
            }
            return textPrimary;
          }),
          side: WidgetStateProperty.all(BorderSide(color: border)),
        ),
      ),

      // Chips
      chipTheme: ChipThemeData(
        backgroundColor: card,
        selectedColor: primarySoft,
        labelStyle: _inter(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          // Material 3 InputChip leaves the label transparent if labelStyle
          // is supplied without a color, so pin one here.
          color: textPrimary,
        ),
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),

      // Dividers
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),

      // List tiles
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        tileColor: Colors.transparent,
        selectedTileColor: primary.withAlpha(isDark ? 20 : 30),
        iconColor: textSecondary,
      ),

      // Bottom sheet
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),

      // Dialog
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: _inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
      ),

      // Snackbar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: snackBarBackground,
        contentTextStyle: _inter(color: snackBarForeground),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),

      // Tab bar
      tabBarTheme: TabBarThemeData(
        labelColor: colorScheme.primary,
        unselectedLabelColor: textSecondary,
        indicatorColor: colorScheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: _inter(fontSize: 14, fontWeight: FontWeight.w600),
        unselectedLabelStyle: _inter(fontSize: 14, fontWeight: FontWeight.w500),
      ),

      // Progress indicators
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: border,
        circularTrackColor: border,
      ),

      // Icons
      iconTheme: IconThemeData(color: textSecondary, size: 24),

      // Popup menu
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: border),
        ),
        textStyle: _inter(fontSize: 14, color: textPrimary),
      ),

      // Expansion tile
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: textSecondary,
        collapsedIconColor: textSecondary,
        textColor: textPrimary,
        collapsedTextColor: textPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),

      // Navigation bar (mobile bottom nav)
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: colorScheme.primary.withAlpha(isDark ? 35 : 30),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return _inter(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? colorScheme.primary : textSecondary,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? colorScheme.primary : textSecondary,
          );
        }),
        elevation: isDark ? 0 : 1,
        surfaceTintColor: Colors.transparent,
      ),

      // Tooltips
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: tooltipBackground,
          borderRadius: BorderRadius.circular(8),
          border: terminalTheme == null && !isDark
              ? null
              : Border.all(color: border),
        ),
        textStyle: _inter(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: tooltipForeground,
        ),
        waitDuration: const Duration(milliseconds: 500),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),

      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onPrimary;
          }
          return textSecondary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return border;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.transparent;
          }
          return border.withAlpha(isDark ? 100 : 180);
        }),
      ),
    );
  }

  static PageTransitionsTheme _buildPageTransitionsTheme(Color background) =>
      PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android:
              PersistentPredictiveBackPageTransitionsBuilder(
                fallbackColor: background,
              ),
          TargetPlatform.iOS: const CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: const CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(
            backgroundColor: background,
          ),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(
            backgroundColor: background,
          ),
        },
      );

  static TextTheme _interTextTheme(TextTheme textTheme) =>
      debugUseSystemFonts ? textTheme : GoogleFonts.interTextTheme(textTheme);

  static TextStyle _inter({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? letterSpacing,
  }) {
    if (debugUseSystemFonts) {
      return TextStyle(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        letterSpacing: letterSpacing,
      );
    }

    return GoogleFonts.inter(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
    );
  }

  static Color _blend(Color background, Color foreground, double amount) =>
      Color.lerp(background, foreground, amount)!;

  static Color _resolveTerminalAccent(TerminalThemeData theme) {
    // Prefer the theme's cursor color when its designer chose a strongly
    // saturated, sufficiently contrasty value. Themes that use a near-neutral
    // cursor (e.g. white-on-black) fall through to the candidate-scoring
    // fallback below so we still pick a vivid accent.
    final cursorHsl = HSLColor.fromColor(theme.cursor);
    if (cursorHsl.saturation >= 0.45 &&
        _contrastRatio(theme.cursor, theme.background) >= 2.5) {
      return theme.cursor;
    }

    final candidates = [
      theme.blue,
      theme.cyan,
      theme.magenta,
      theme.green,
      theme.brightBlue,
      theme.brightCyan,
      theme.brightMagenta,
      theme.cursor,
      theme.yellow,
      theme.red,
    ];
    var bestColor = candidates.first;
    var bestScore = double.negativeInfinity;

    for (final candidate in candidates) {
      final hsl = HSLColor.fromColor(candidate);
      final balance = 1 - (hsl.lightness - 0.5).abs();
      final score =
          _contrastRatio(candidate, theme.background) +
          (hsl.saturation * 2) +
          balance;
      if (score > bestScore) {
        bestColor = candidate;
        bestScore = score;
      }
    }

    return bestColor;
  }

  static Color _readableTextColor(Color background) =>
      _contrastRatio(Colors.white, background) >
          _contrastRatio(Colors.black, background)
      ? Colors.white
      : Colors.black;

  static double _contrastRatio(Color a, Color b) {
    final luminanceA = a.computeLuminance();
    final luminanceB = b.computeLuminance();
    final lighter = luminanceA > luminanceB ? luminanceA : luminanceB;
    final darker = luminanceA > luminanceB ? luminanceB : luminanceA;
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Monospace text style for terminal/code content.
  static TextStyle get monoStyle => debugUseSystemFonts
      ? const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          fontWeight: FontWeight.w400,
        )
      : GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w400);

  /// Accent gradient for special elements.
  static LinearGradient get accentGradient => const LinearGradient(
    colors: [_accentTeal, _accentTealSoft],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Glow box shadow for cards/buttons.
  static List<BoxShadow> glowShadow([Color? color]) => [
    BoxShadow(color: (color ?? _accentTeal).withAlpha(40), blurRadius: 20),
  ];

  /// Builds a consistent empty-state placeholder widget.
  ///
  /// Use across all panels and screens for visual consistency.
  static Widget buildEmptyState({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onAction,
    String? actionLabel,
    IconData? actionIcon,
    bool centered = true,
    bool padded = true,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    Widget child = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(spacingMd),
          decoration: BoxDecoration(
            color: colorScheme.primary.withAlpha(
              theme.brightness == Brightness.dark ? 15 : 10,
            ),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: emptyStateIconSize,
            color: colorScheme.onSurface.withAlpha(80),
          ),
        ),
        const SizedBox(height: spacingMd),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            color: colorScheme.onSurface.withAlpha(180),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: spacingXs),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurface.withAlpha(100),
          ),
        ),
        if (onAction != null && actionLabel != null) ...[
          const SizedBox(height: spacingLg),
          FilledButton.icon(
            onPressed: onAction,
            icon: Icon(actionIcon ?? Icons.add, size: 18),
            label: Text(actionLabel),
          ),
        ],
      ],
    );

    if (padded) {
      child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: spacingLg),
        child: child,
      );
    }

    if (centered) {
      child = Center(child: child);
    }

    return child;
  }
}

/// Android predictive-back transition that keeps the outgoing page painted.
///
/// Flutter's default shared-element predictive-back transition fades the
/// outgoing route after the commit threshold. Full-screen terminal surfaces make
/// that look like the terminal itself turns into a grey box, so this transition
/// follows the back gesture with the same shrinking motion but does not fade the
/// outgoing child before the route is removed.
class PersistentPredictiveBackPageTransitionsBuilder
    extends PageTransitionsBuilder {
  /// Creates a persistent Android predictive-back transition.
  const PersistentPredictiveBackPageTransitionsBuilder({this.fallbackColor});

  /// Background used by the non-predictive fallback transition.
  final Color? fallbackColor;

  @override
  Duration get transitionDuration => const Duration(
    milliseconds: FadeForwardsPageTransitionsBuilder.kTransitionMilliseconds,
  );

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    Widget buildPredictiveTransition(
      BuildContext context,
      _AndroidBackPhase phase,
      PredictiveBackEvent? startBackEvent,
      PredictiveBackEvent? currentBackEvent, {
      required bool passThrough,
    }) {
      final ownsPredictiveGesture = phase != _AndroidBackPhase.idle;
      final suppressFallbackMotion = ownsPredictiveGesture || passThrough;
      final persistentChild = _PersistentPredictiveBackTransition(
        active: ownsPredictiveGesture,
        animation: animation,
        phase: phase,
        startBackEvent: startBackEvent,
        currentBackEvent: currentBackEvent,
        child: child,
      );
      if (suppressFallbackMotion) {
        return persistentChild;
      }
      return FadeForwardsPageTransitionsBuilder(
        backgroundColor: fallbackColor,
      ).buildTransitions(
        route,
        context,
        animation,
        secondaryAnimation,
        persistentChild,
      );
    }

    return _AndroidBackGestureDetector(
      route: route,
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      builder: buildPredictiveTransition,
    );
  }
}

enum _AndroidBackPhase { idle, start, update, commit, cancel }

final ValueNotifier<_AndroidBackGestureSnapshot> _androidBackGestureSnapshot =
    ValueNotifier<_AndroidBackGestureSnapshot>(
      _AndroidBackGestureSnapshot.idle,
    );

@immutable
class _AndroidBackGestureSnapshot {
  const _AndroidBackGestureSnapshot({
    required this.active,
    required this.owner,
  });

  static const idle = _AndroidBackGestureSnapshot(active: false, owner: null);

  final bool active;
  final Object? owner;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _AndroidBackGestureSnapshot &&
          active == other.active &&
          identical(owner, other.owner);

  @override
  int get hashCode => Object.hash(active, identityHashCode(owner));
}

class _AndroidBackGestureDetector extends StatefulWidget {
  const _AndroidBackGestureDetector({
    required this.route,
    required this.animation,
    required this.secondaryAnimation,
    required this.builder,
  });

  final PageRoute<dynamic> route;
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget Function(
    BuildContext context,
    _AndroidBackPhase phase,
    PredictiveBackEvent? startBackEvent,
    PredictiveBackEvent? currentBackEvent, {
    required bool passThrough,
  })
  builder;

  @override
  State<_AndroidBackGestureDetector> createState() =>
      _AndroidBackGestureDetectorState();
}

class _AndroidBackGestureDetectorState
    extends State<_AndroidBackGestureDetector>
    with WidgetsBindingObserver {
  _AndroidBackPhase _phase = _AndroidBackPhase.idle;
  PredictiveBackEvent? _startBackEvent;
  PredictiveBackEvent? _currentBackEvent;
  bool _gestureAccepted = false;
  String? _lastTransitionDiagnosticsKey;

  bool get _isEnabled =>
      widget.route.isCurrent && widget.route.popGestureEnabled;

  void _publishGlobalGestureState(bool active) {
    final nextSnapshot = active
        ? _AndroidBackGestureSnapshot(active: true, owner: this)
        : _AndroidBackGestureSnapshot.idle;
    if (_androidBackGestureSnapshot.value == nextSnapshot) {
      return;
    }
    _androidBackGestureSnapshot.value = nextSnapshot;
  }

  void _clearGlobalGestureState() {
    if (_androidBackGestureSnapshot.value.owner == this) {
      _publishGlobalGestureState(false);
    }
  }

  void _setGestureState({
    required bool accepted,
    required _AndroidBackPhase phase,
    PredictiveBackEvent? startBackEvent,
    PredictiveBackEvent? currentBackEvent,
  }) {
    void apply() {
      _gestureAccepted = accepted;
      _phase = phase;
      _startBackEvent = startBackEvent;
      _currentBackEvent = currentBackEvent;
    }

    if (!mounted) {
      apply();
      return;
    }

    setState(apply);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    _clearFinishedGestureState();
  }

  void _clearFinishedGestureState() {
    if (!_gestureAccepted) {
      return;
    }
    if (_phase == _AndroidBackPhase.cancel &&
        widget.animation.status == AnimationStatus.completed) {
      _clearGlobalGestureState();
      _setGestureState(accepted: false, phase: _AndroidBackPhase.idle);
    } else if (_phase == _AndroidBackPhase.commit &&
        widget.animation.status == AnimationStatus.dismissed) {
      _clearGlobalGestureState();
    }
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final gestureInProgress = !backEvent.isButtonEvent && _isEnabled;
    if (!gestureInProgress) {
      _setGestureState(accepted: false, phase: _AndroidBackPhase.idle);
      _logTransitionState(
        event: 'start',
        backEvent: backEvent,
        accepted: false,
      );
      return false;
    }

    _setGestureState(
      accepted: true,
      phase: _AndroidBackPhase.start,
      startBackEvent: backEvent,
      currentBackEvent: backEvent,
    );
    _publishGlobalGestureState(true);
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    _logTransitionState(event: 'start', backEvent: backEvent, accepted: true);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_gestureAccepted) {
      _logTransitionState(event: 'update_ignored', backEvent: backEvent);
      return;
    }
    _setGestureState(
      accepted: true,
      phase: _AndroidBackPhase.update,
      startBackEvent: _startBackEvent,
      currentBackEvent: backEvent,
    );
    _publishGlobalGestureState(true);
    widget.route.handleUpdateBackGestureProgress(
      progress: 1 - backEvent.progress,
    );
    _logTransitionState(event: 'update', backEvent: backEvent);
  }

  @override
  void handleCancelBackGesture() {
    if (!_gestureAccepted) {
      _logTransitionState(event: 'cancel_ignored');
      return;
    }
    final startBackEvent = _startBackEvent;
    final currentBackEvent = _currentBackEvent;
    _setGestureState(
      accepted: true,
      phase: _AndroidBackPhase.cancel,
      startBackEvent: startBackEvent,
      currentBackEvent: currentBackEvent,
    );
    _publishGlobalGestureState(true);
    widget.route.handleCancelBackGesture();
    _clearFinishedGestureState();
    _logTransitionState(event: 'cancel', backEvent: currentBackEvent);
  }

  @override
  void handleCommitBackGesture() {
    if (!_gestureAccepted) {
      _logTransitionState(event: 'commit_ignored');
      return;
    }
    final startBackEvent = _startBackEvent;
    final currentBackEvent = _currentBackEvent;
    _setGestureState(
      accepted: true,
      phase: _AndroidBackPhase.commit,
      startBackEvent: startBackEvent,
      currentBackEvent: currentBackEvent,
    );
    _publishGlobalGestureState(true);
    widget.route.handleCommitBackGesture();
    _clearFinishedGestureState();
    _logTransitionState(event: 'commit', backEvent: currentBackEvent);
  }

  void _logTransitionState({
    required String event,
    _AndroidBackPhase? effectivePhase,
    String? branch,
    PredictiveBackEvent? backEvent,
    bool? accepted,
  }) {
    final diagnostics = DiagnosticsLogService.instance;
    if (!diagnostics.enabled ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    final fields = <String, Object?>{
      'event': event,
      'phase': effectivePhase ?? _phase,
      'branch': branch,
      'accepted': accepted,
      'gestureAccepted': _gestureAccepted,
      'routeType': widget.route.runtimeType.toString(),
      'routePopGestureInProgress': widget.route.popGestureInProgress,
      'routePopGestureEnabled': widget.route.popGestureEnabled,
      'routeIsCurrent': widget.route.isCurrent,
      'routeCanPop': widget.route.canPop,
      'animationStatus': widget.animation.status,
      'animationBucket': _animationBucket(widget.animation),
      'secondaryAnimationStatus': widget.secondaryAnimation.status,
      'secondaryAnimationBucket': _animationBucket(widget.secondaryAnimation),
      'isButtonEvent': backEvent?.isButtonEvent,
      'eventProgressPermille': backEvent == null
          ? null
          : (backEvent.progress * 1000).round(),
      'swipeEdge': backEvent?.swipeEdge,
    };
    final key = fields.entries
        .map((entry) => '${entry.key}:${entry.value}')
        .join('|');
    if (key == _lastTransitionDiagnosticsKey) {
      return;
    }
    _lastTransitionDiagnosticsKey = key;
    diagnostics.debug('android.back', 'transition_state', fields: fields);
  }

  int? _animationBucket(Animation<double> animation) {
    final value = animation.value;
    return (clampDouble(value, 0, 1) * 20).round();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.animation.addStatusListener(_handleAnimationStatus);
  }

  @override
  void didUpdateWidget(covariant _AndroidBackGestureDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animation != oldWidget.animation) {
      oldWidget.animation.removeStatusListener(_handleAnimationStatus);
      widget.animation.addStatusListener(_handleAnimationStatus);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.animation.removeStatusListener(_handleAnimationStatus);
    _clearGlobalGestureState();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<_AndroidBackGestureSnapshot>(
        valueListenable: _androidBackGestureSnapshot,
        builder: (context, globalGestureSnapshot, _) {
          final routeGestureInProgress = widget.route.popGestureInProgress;
          final phase = routeGestureInProgress && _gestureAccepted
              ? _phase
              : _AndroidBackPhase.idle;
          final passThrough =
              (routeGestureInProgress || globalGestureSnapshot.active) &&
              !_gestureAccepted;
          final branch = switch ((phase, passThrough)) {
            (_AndroidBackPhase.idle, true) => 'pass_through',
            (_AndroidBackPhase.idle, false) => 'fallback',
            _ => 'persistent',
          };
          _logTransitionState(
            event: 'build',
            effectivePhase: phase,
            branch: branch,
          );
          return widget.builder(
            context,
            phase,
            _startBackEvent,
            _currentBackEvent,
            passThrough: passThrough,
          );
        },
      );
}

class _PersistentPredictiveBackTransition extends StatefulWidget {
  const _PersistentPredictiveBackTransition({
    required this.active,
    required this.animation,
    required this.phase,
    required this.startBackEvent,
    required this.currentBackEvent,
    required this.child,
  });

  final bool active;
  final Animation<double> animation;
  final _AndroidBackPhase phase;
  final PredictiveBackEvent? startBackEvent;
  final PredictiveBackEvent? currentBackEvent;
  final Widget child;

  @override
  State<_PersistentPredictiveBackTransition> createState() =>
      _PersistentPredictiveBackTransitionState();
}

class _PersistentPredictiveBackTransitionState
    extends State<_PersistentPredictiveBackTransition> {
  static const double _minScale = 0.90;
  static const double _screenWidthDivisionFactor = 20;
  static const double _xShiftAdjustment = 8;
  static const double _fallbackDeviceBorderRadius = 32;

  double _lastProgress = 0;
  double _lastVerticalDrag = 0;
  SwipeEdge _lastSwipeEdge = SwipeEdge.left;

  double _progress() {
    if (!widget.active) {
      _lastProgress = 0;
      _lastVerticalDrag = 0;
      return 0;
    }

    final currentProgress = switch (widget.phase) {
      _AndroidBackPhase.start ||
      _AndroidBackPhase.update => widget.currentBackEvent?.progress,
      _ => null,
    };
    if (currentProgress != null) {
      return _lastProgress = clampDouble(currentProgress, 0, 1);
    }

    final animationProgress = clampDouble(1 - widget.animation.value, 0, 1);
    if (widget.phase == _AndroidBackPhase.commit) {
      if (animationProgress > _lastProgress) {
        _lastProgress = animationProgress;
      }
      return _lastProgress;
    }

    return _lastProgress = animationProgress;
  }

  double _maxShift(double extent) => clampDouble(
    (extent / _screenWidthDivisionFactor) - _xShiftAdjustment,
    0,
    double.infinity,
  );

  SwipeEdge _swipeEdge(Size size) {
    final touchOffset =
        widget.startBackEvent?.touchOffset ??
        widget.currentBackEvent?.touchOffset;
    final touchX = touchOffset?.dx;
    if (touchX != null && touchX.isFinite && size.width > 0) {
      return _lastSwipeEdge = touchX > size.width / 2
          ? SwipeEdge.right
          : SwipeEdge.left;
    }

    final swipeEdge =
        widget.startBackEvent?.swipeEdge ?? widget.currentBackEvent?.swipeEdge;
    if (swipeEdge != null) {
      _lastSwipeEdge = swipeEdge;
    }
    return _lastSwipeEdge;
  }

  double _verticalDrag(Size size) {
    final startTouchY = widget.startBackEvent?.touchOffset?.dy;
    final currentTouchY = widget.currentBackEvent?.touchOffset?.dy;
    if (startTouchY == null || currentTouchY == null || size.height <= 0) {
      return _lastVerticalDrag;
    }

    final maxShift = _maxShift(size.height);
    final rawDrag = currentTouchY - startTouchY;
    final easedDrag =
        Curves.easeOut.transform(
          clampDouble(rawDrag.abs() / size.height, 0, 1),
        ) *
        rawDrag.sign *
        maxShift;
    return _lastVerticalDrag = clampDouble(easedDrag, -maxShift, maxShift);
  }

  Offset _offset(Size size, double progress) {
    final xShift = _maxShift(size.width) * progress;
    final direction = switch (_swipeEdge(size)) {
      SwipeEdge.right => -1.0,
      SwipeEdge.left => 1.0,
    };
    return Offset(direction * xShift, _verticalDrag(size));
  }

  Alignment _scaleAlignment(Size size) => switch (_swipeEdge(size)) {
    SwipeEdge.right => Alignment.centerLeft,
    SwipeEdge.left => Alignment.centerRight,
  };

  BorderRadius _borderRadius(BuildContext context, double progress) {
    if (!widget.active) {
      return BorderRadius.zero;
    }
    return MediaQuery.displayCornerRadiiOf(context) ??
        BorderRadius.circular(_fallbackDeviceBorderRadius * progress);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.animation,
    builder: (context, child) {
      final size = MediaQuery.sizeOf(context);
      final progress = _progress();
      final scale = 1 - ((1 - _minScale) * progress);
      return Transform.translate(
        offset: _offset(size, progress),
        child: Transform.scale(
          alignment: _scaleAlignment(size),
          scale: scale,
          child: ClipRRect(
            borderRadius: _borderRadius(context, progress),
            child: child,
          ),
        ),
      );
    },
    child: widget.child,
  );
}
