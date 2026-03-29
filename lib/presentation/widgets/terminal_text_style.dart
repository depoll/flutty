import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Resolves an optional configured monospace [TextStyle].
///
/// Returns null for the system monospace option so callers can decide whether
/// to fall back to a plain [TextStyle] or a different default.
TextStyle? resolveConfiguredMonospaceTextStyle(
  String fontFamily, {
  required double fontSize,
}) => switch (fontFamily) {
  'JetBrains Mono' => GoogleFonts.jetBrainsMono(fontSize: fontSize),
  'Fira Code' => GoogleFonts.firaCode(fontSize: fontSize),
  'Source Code Pro' => GoogleFonts.sourceCodePro(fontSize: fontSize),
  'Ubuntu Mono' => GoogleFonts.ubuntuMono(fontSize: fontSize),
  'Roboto Mono' => GoogleFonts.robotoMono(fontSize: fontSize),
  'IBM Plex Mono' => GoogleFonts.ibmPlexMono(fontSize: fontSize),
  'Inconsolata' => GoogleFonts.inconsolata(fontSize: fontSize),
  'Anonymous Pro' => GoogleFonts.anonymousPro(fontSize: fontSize),
  'Cousine' => GoogleFonts.cousine(fontSize: fontSize),
  'PT Mono' => GoogleFonts.ptMono(fontSize: fontSize),
  'Space Mono' => GoogleFonts.spaceMono(fontSize: fontSize),
  'VT323' => GoogleFonts.vt323(fontSize: fontSize),
  'Share Tech Mono' => GoogleFonts.shareTechMono(fontSize: fontSize),
  'Overpass Mono' => GoogleFonts.overpassMono(fontSize: fontSize),
  'Oxygen Mono' => GoogleFonts.oxygenMono(fontSize: fontSize),
  _ => null,
};

/// Resolves the monospace [TextStyle] used for terminal and editor content.
TextStyle resolveMonospaceTextStyle(
  String fontFamily, {
  required double fontSize,
}) =>
    resolveConfiguredMonospaceTextStyle(fontFamily, fontSize: fontSize) ??
    TextStyle(fontFamily: 'monospace', fontSize: fontSize);
