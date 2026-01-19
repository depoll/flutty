import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Theme configuration for the Flutty app.
/// Inspired by Termius with a modern hacker aesthetic.
abstract final class FluttyTheme {
  // Core palette - deep space with neon accents
  static const _neonGreen = Color(0xFF00FF6A);
  static const _neonGreenDim = Color(0xFF00D26A);
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

  /// Light theme.
  static ThemeData get light => _buildTheme(Brightness.light);

  /// Dark theme.
  static ThemeData get dark => _buildTheme(Brightness.dark);

  static ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: isDark ? _neonGreen : _neonGreenDim,
      onPrimary: Colors.black,
      secondary: isDark ? _cardDark : _surfaceLight,
      onSecondary: isDark ? _textPrimary : Colors.black87,
      tertiary: _warningColor,
      onTertiary: Colors.black,
      error: _errorColor,
      onError: Colors.white,
      surface: isDark ? _surfaceDark : _surfaceLight,
      onSurface: isDark ? _textPrimary : Colors.black87,
      surfaceContainerHighest: isDark ? _cardDark : _cardLight,
      outline: isDark ? _borderDark : _borderLight,
      outlineVariant: isDark ? _borderDark.withAlpha(128) : _borderLight,
    );

    // Use JetBrains Mono for that terminal feel, Inter for UI
    final baseTextTheme = isDark 
        ? ThemeData.dark().textTheme 
        : ThemeData.light().textTheme;
    
    final textTheme = GoogleFonts.interTextTheme(baseTextTheme).copyWith(
      // Headings with more weight
      headlineLarge: GoogleFonts.inter(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: isDark ? _textPrimary : Colors.black87,
        letterSpacing: -0.5,
      ),
      headlineMedium: GoogleFonts.inter(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: isDark ? _textPrimary : Colors.black87,
        letterSpacing: -0.3,
      ),
      headlineSmall: GoogleFonts.inter(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: isDark ? _textPrimary : Colors.black87,
      ),
      titleLarge: GoogleFonts.inter(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: isDark ? _textPrimary : Colors.black87,
      ),
      titleMedium: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: isDark ? _textPrimary : Colors.black87,
      ),
      bodyLarge: GoogleFonts.inter(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: isDark ? _textPrimary : Colors.black87,
      ),
      bodyMedium: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: isDark ? _textSecondary : Colors.black54,
      ),
      bodySmall: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: isDark ? _textSecondary : Colors.black54,
      ),
      labelLarge: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: isDark ? _textPrimary : Colors.black87,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: isDark ? _backgroundDark : _backgroundLight,
      
      // App bar with subtle blur effect vibe
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? _backgroundDark : _backgroundLight,
        foregroundColor: isDark ? _textPrimary : Colors.black87,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: isDark ? _textPrimary : Colors.black87,
        ),
      ),
      
      // Cards with subtle glow on dark theme
      cardTheme: CardThemeData(
        color: isDark ? _cardDark : _cardLight,
        elevation: isDark ? 0 : 1,
        shadowColor: isDark ? _neonGreen.withAlpha(20) : Colors.black12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isDark ? _borderDark : _borderLight,
            width: 1,
          ),
        ),
        margin: EdgeInsets.zero,
      ),
      
      // Glowing FAB
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: _neonGreen,
        foregroundColor: Colors.black,
        elevation: isDark ? 8 : 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      
      // Modern input fields
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? _cardDark : Colors.grey.shade50,
        hoverColor: isDark ? _borderDark : Colors.grey.shade100,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isDark ? _borderDark : _borderLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isDark ? _borderDark : _borderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _neonGreen, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _errorColor),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        labelStyle: TextStyle(color: isDark ? _textSecondary : Colors.black54),
        hintStyle: TextStyle(color: isDark ? _textSecondary.withAlpha(150) : Colors.black38),
        prefixIconColor: isDark ? _textSecondary : Colors.black45,
      ),
      
      // Buttons with glow
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: _neonGreen,
          foregroundColor: Colors.black,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _neonGreen,
          foregroundColor: Colors.black,
          elevation: isDark ? 4 : 2,
          shadowColor: isDark ? _neonGreen.withAlpha(80) : Colors.black26,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: isDark ? _textPrimary : Colors.black87,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: isDark ? _borderDark : _borderLight, width: 1.5),
          textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: _neonGreen,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      
      // Segmented buttons
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return _neonGreen;
            }
            return isDark ? _cardDark : _cardLight;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return Colors.black;
            }
            return isDark ? _textPrimary : Colors.black87;
          }),
          side: WidgetStateProperty.all(
            BorderSide(color: isDark ? _borderDark : _borderLight),
          ),
        ),
      ),
      
      // Chips
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? _cardDark : _cardLight,
        selectedColor: _neonGreen,
        labelStyle: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w500),
        side: BorderSide(color: isDark ? _borderDark : _borderLight),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      
      // Dividers
      dividerTheme: DividerThemeData(
        color: isDark ? _borderDark : _borderLight,
        thickness: 1,
        space: 1,
      ),
      
      // List tiles
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        tileColor: Colors.transparent,
        selectedTileColor: isDark ? _neonGreen.withAlpha(20) : _neonGreen.withAlpha(30),
        iconColor: isDark ? _textSecondary : Colors.black54,
      ),
      
      // Bottom sheet
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? _surfaceDark : _surfaceLight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      
      // Dialog
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? _surfaceDark : _surfaceLight,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: isDark ? _textPrimary : Colors.black87,
        ),
      ),
      
      // Snackbar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? _cardDark : Colors.grey.shade900,
        contentTextStyle: GoogleFonts.inter(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      
      // Tab bar
      tabBarTheme: TabBarThemeData(
        labelColor: _neonGreen,
        unselectedLabelColor: isDark ? _textSecondary : Colors.black54,
        indicatorColor: _neonGreen,
        indicatorSize: TabBarIndicatorSize.label,
        labelStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
        unselectedLabelStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      
      // Progress indicators
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: _neonGreen,
        linearTrackColor: isDark ? _borderDark : _borderLight,
        circularTrackColor: isDark ? _borderDark : _borderLight,
      ),
      
      // Icons
      iconTheme: IconThemeData(
        color: isDark ? _textSecondary : Colors.black54,
        size: 24,
      ),
      
      // Popup menu
      popupMenuTheme: PopupMenuThemeData(
        color: isDark ? _cardDark : _cardLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: isDark ? _borderDark : _borderLight),
        ),
        textStyle: GoogleFonts.inter(
          fontSize: 14,
          color: isDark ? _textPrimary : Colors.black87,
        ),
      ),
      
      // Expansion tile
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: isDark ? _textSecondary : Colors.black54,
        collapsedIconColor: isDark ? _textSecondary : Colors.black54,
        textColor: isDark ? _textPrimary : Colors.black87,
        collapsedTextColor: isDark ? _textPrimary : Colors.black87,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// Monospace text style for terminal/code content.
  static TextStyle get monoStyle => GoogleFonts.jetBrainsMono(
    fontSize: 13,
    fontWeight: FontWeight.w400,
  );

  /// Accent gradient for special elements.
  static LinearGradient get accentGradient => const LinearGradient(
    colors: [_neonGreen, Color(0xFF00C9FF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Glow box shadow for cards/buttons.
  static List<BoxShadow> glowShadow([Color? color]) => [
    BoxShadow(
      color: (color ?? _neonGreen).withAlpha(40),
      blurRadius: 20,
      spreadRadius: 0,
    ),
  ];
}
