// Sonus Auris console brand: a deep blue/teal "audio wave" palette shared in
// spirit with the mobile app, expressed as Material 3 themes for light + dark.
import 'package:flutter/material.dart';

const Color sonusDeepBlue = Color(0xFF0B2A4A);
const Color sonusTeal = Color(0xFF17B6B0);
const Color sonusAmber = Color(0xFFF2A73B);

ThemeData consoleTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: sonusTeal,
    brightness: brightness,
    primary: brightness == Brightness.dark ? sonusTeal : sonusDeepBlue,
    secondary: sonusTeal,
    tertiary: sonusAmber,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      filled: true,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
  );
}
