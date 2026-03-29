import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Resolves the platform-specific system monospace family.
String resolveMonospaceFontFamily(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => 'Menlo',
      _ => 'monospace',
    };

/// Resolves fallback families for the shared monospace stack.
List<String> resolveMonospaceFontFallback(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.iOS ||
      TargetPlatform.macOS => const ['Courier', 'Courier New', 'monospace'],
      TargetPlatform.windows => const ['Consolas', 'Courier New', 'monospace'],
      _ => const ['monospace'],
    };

/// Resolves the effective monospace text style for terminal-like surfaces.
TextStyle resolveMonospaceTextStyle(
  String fontFamily, {
  required TargetPlatform platform,
  double? fontSize,
}) {
  final fallback = resolveMonospaceFontFallback(platform);
  final textStyle = switch (fontFamily) {
    'JetBrains Mono' => GoogleFonts.jetBrainsMono(),
    'Fira Code' => GoogleFonts.firaCode(),
    'Source Code Pro' => GoogleFonts.sourceCodePro(),
    'Ubuntu Mono' => GoogleFonts.ubuntuMono(),
    'Roboto Mono' => GoogleFonts.robotoMono(),
    'IBM Plex Mono' => GoogleFonts.ibmPlexMono(),
    'Inconsolata' => GoogleFonts.inconsolata(),
    'Anonymous Pro' => GoogleFonts.anonymousPro(),
    'Cousine' => GoogleFonts.cousine(),
    'PT Mono' => GoogleFonts.ptMono(),
    'Space Mono' => GoogleFonts.spaceMono(),
    'VT323' => GoogleFonts.vt323(),
    'Share Tech Mono' => GoogleFonts.shareTechMono(),
    'Overpass Mono' => GoogleFonts.overpassMono(),
    'Oxygen Mono' => GoogleFonts.oxygenMono(),
    'monospace' => TextStyle(
      fontFamily: resolveMonospaceFontFamily(platform),
      fontFamilyFallback: fallback,
    ),
    _ => TextStyle(fontFamily: fontFamily, fontFamilyFallback: fallback),
  };
  if (fontSize == null) {
    return textStyle;
  }
  return textStyle.copyWith(fontSize: fontSize);
}
