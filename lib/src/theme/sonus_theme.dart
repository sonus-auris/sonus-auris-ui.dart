// Sonus Auris brand colors and Material theme, mirrored from the marketing site.
import 'package:flutter/material.dart';

/// Sonus Auris brand palette, mirrored from the marketing site's
/// `src/styles/global.css` (green + orange, "fun but professional").
class SonusColors {
  SonusColors._();

  static const green900 = Color(0xFF0C3B2E);
  static const green700 = Color(0xFF136F4F);
  static const green500 = Color(0xFF1FAA6C);
  static const green400 = Color(0xFF34C585);
  static const green200 = Color(0xFFB7F0D2);
  static const green50 = Color(0xFFEAFAF1);

  static const orange600 = Color(0xFFE8590C);
  static const orange500 = Color(0xFFFD7E14);
  static const orange400 = Color(0xFFFF9F43);
  static const orange200 = Color(0xFFFFE0BD);

  static const ink = Color(0xFF0C2A22);
  static const inkSoft = Color(0xFF355A4F);
  static const paper = Color(0xFFFFFDF8);
  static const paper2 = Color(0xFFF4FBF6);

  /// Hairline border used on cards (matches the site's rgba(12,59,46,0.08)).
  static const hairline = Color(0x140C3B2E);

  /// The site's primary CTA gradient (orange) and the brand mark gradient.
  static const ctaGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [orange500, orange600],
  );
  static const markGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [green400, green700],
  );
}

const String kSonusFontFamily = 'Baloo 2';

/// Soft brand shadows mirrored from the site's --shadow-sm / --shadow-md.
const List<BoxShadow> kSonusShadowSm = [
  BoxShadow(color: Color(0x140C3B2E), blurRadius: 8, offset: Offset(0, 2)),
];
const List<BoxShadow> kSonusShadowMd = [
  BoxShadow(color: Color(0x240C3B2E), blurRadius: 30, offset: Offset(0, 12)),
];

/// Builds the app-wide Material 3 theme styled after the Sonus Auris site:
/// rounded Baloo 2 type, paper background, green primary + orange CTA accent,
/// pill buttons, and large-radius cards.
ThemeData buildSonusTheme() {
  final base = ColorScheme.fromSeed(
    seedColor: SonusColors.green700,
    brightness: Brightness.light,
  );
  final scheme = base.copyWith(
    primary: SonusColors.green700,
    onPrimary: Colors.white,
    primaryContainer: SonusColors.green50,
    onPrimaryContainer: SonusColors.green900,
    secondary: SonusColors.orange500,
    onSecondary: Colors.white,
    secondaryContainer: SonusColors.orange200,
    onSecondaryContainer: SonusColors.orange600,
    tertiary: SonusColors.green400,
    surface: Colors.white,
    onSurface: SonusColors.ink,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: SonusColors.paper2,
    surfaceContainer: SonusColors.paper2,
    surfaceContainerHigh: SonusColors.green50,
    onSurfaceVariant: SonusColors.inkSoft,
    outline: const Color(0x33136F4F),
    outlineVariant: SonusColors.green200,
  );

  TextStyle heading(double size, [FontWeight w = FontWeight.w800]) => TextStyle(
    fontFamily: kSonusFontFamily,
    color: SonusColors.ink,
    fontWeight: w,
    fontSize: size,
    height: 1.15,
    letterSpacing: -0.4,
  );
  TextStyle body(double size, [Color? color]) => TextStyle(
    fontFamily: kSonusFontFamily,
    color: color ?? SonusColors.ink,
    fontWeight: FontWeight.w500,
    fontSize: size,
    height: 1.4,
  );

  final textTheme = TextTheme(
    displaySmall: heading(34),
    headlineMedium: heading(28),
    headlineSmall: heading(23),
    titleLarge: heading(20),
    titleMedium: heading(17),
    titleSmall: heading(15, FontWeight.w700),
    bodyLarge: body(16),
    bodyMedium: body(14),
    bodySmall: body(12.5, SonusColors.inkSoft),
    labelLarge: const TextStyle(
      fontFamily: kSonusFontFamily,
      fontWeight: FontWeight.w800,
      fontSize: 15,
      letterSpacing: 0.1,
    ),
  );

  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: kSonusFontFamily,
    scaffoldBackgroundColor: SonusColors.paper,
    textTheme: textTheme,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: SonusColors.paper.withValues(alpha: 0.94),
      surfaceTintColor: Colors.transparent,
      foregroundColor: SonusColors.ink,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      shadowColor: SonusColors.hairline,
      titleTextStyle: heading(20),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: SonusColors.hairline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: pill,
        textStyle: textTheme.labelLarge,
        backgroundColor: SonusColors.green700,
        foregroundColor: Colors.white,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: pill,
        elevation: 0,
        textStyle: textTheme.labelLarge,
        backgroundColor: SonusColors.green700,
        foregroundColor: Colors.white,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        shape: pill,
        foregroundColor: SonusColors.green900,
        backgroundColor: Colors.white,
        side: const BorderSide(color: SonusColors.green200, width: 1.5),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: SonusColors.green700,
        textStyle: textTheme.labelLarge,
        shape: pill,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: SonusColors.green700),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: SonusColors.green50,
      side: const BorderSide(color: SonusColors.green200),
      labelStyle: const TextStyle(
        fontFamily: kSonusFontFamily,
        color: SonusColors.green700,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: SonusColors.paper2,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: const TextStyle(color: SonusColors.inkSoft),
      labelStyle: const TextStyle(color: SonusColors.inkSoft),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: SonusColors.green200),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: SonusColors.green200),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: SonusColors.green500, width: 2),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: SonusColors.paper,
      surfaceTintColor: Colors.transparent,
      indicatorColor: SonusColors.green50,
      elevation: 0,
      height: 66,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: kSonusFontFamily,
          fontWeight: FontWeight.w700,
          fontSize: 12,
          color: states.contains(WidgetState.selected)
              ? SonusColors.green900
              : SonusColors.inkSoft,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? SonusColors.green700
              : SonusColors.inkSoft,
        ),
      ),
    ),
    bannerTheme: const MaterialBannerThemeData(
      backgroundColor: SonusColors.green50,
      contentTextStyle: TextStyle(
        fontFamily: kSonusFontFamily,
        color: SonusColors.ink,
        fontWeight: FontWeight.w600,
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : Colors.white,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? SonusColors.green500
            : const Color(0xFFD3E2DA),
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: SonusColors.green500,
      inactiveTrackColor: SonusColors.green200,
      thumbColor: SonusColors.green700,
      overlayColor: Color(0x331FAA6C),
    ),
    dividerTheme: const DividerThemeData(
      color: SonusColors.hairline,
      space: 1,
      thickness: 1,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: SonusColors.green500,
    ),
    dropdownMenuTheme: const DropdownMenuThemeData(
      textStyle: TextStyle(fontFamily: kSonusFontFamily, color: SonusColors.ink),
    ),
  );
}
