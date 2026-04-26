import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // Light Mode
  static const primary = Color(0xFF003366); // UnB Navy Blue
  static const accent = Color(0xFF00C97A);  // Vibrant Glow Green
  static const accentLight = Color(0xFF00C97A); // Use accent for light variant
  static const teal = Color(0xFF006633);    // Dark UnB Green
  static const surface = Color(0xFFF8FAFC); // Neutral light background
  static const card = Color(0xFFFFFFFF);    // Pure white
  static const muted = Color(0xFF8B8B99);
  static const mapBg = Color(0xFFE8EFF8);
  static const purple = Color(0xFF7B8FF7);

  // Dark Mode
  static const darkPrimary = Color(0xFFF8FAFC); // Use surface for dark primary
  static const darkAccent = Color(0xFF00C97A);
  static const darkSurface = Color(0xFF0F0F1E);
  static const darkCard = Color(0xFF003366); // Navy for dark card
  static const darkMuted = Color(0xFF6B6B7D);
  static const darkMapBg = Color(0xFF2A2A42);
  static const darkTeal = Color(0xFF006633);
  static const darkPurple = Color(0xFF7B8FF7);

  // Status (same in both modes for legibility)
  static const statusPreparing = Color(0xFFFFF3EE);
  static const statusPreparingText = Color(0xFFFF6B35);
  static const statusDelivered = Color(0xFFEDFCF8);
  static const statusDeliveredText = Color(0xFF0D9E75);
  static const statusPending = Color(0xFFFFF8EE);
  static const statusPendingText = Color(0xFFB97A00);
}

/// Resolves adaptive colors from BuildContext brightness.
class AC {
  static Color primary(BuildContext context) =>
      _dark(context) ? AppColors.darkPrimary : AppColors.primary;
  static Color surface(BuildContext context) =>
      _dark(context) ? AppColors.darkSurface : AppColors.surface;
  static Color card(BuildContext context) =>
      _dark(context) ? AppColors.darkCard : AppColors.card;
  static Color muted(BuildContext context) =>
      _dark(context) ? AppColors.darkMuted : AppColors.muted;
  static Color mapBg(BuildContext context) =>
      _dark(context) ? AppColors.darkMapBg : AppColors.mapBg;
    static Color border(BuildContext context) =>
      _dark(context)
        ? AppColors.darkPrimary.withValues(alpha: 0.12)
        : AppColors.primary.withValues(alpha: 0.08);
  static Color accent(BuildContext _) => AppColors.accent;
  static Color teal(BuildContext _) => AppColors.teal;
  static Color purple(BuildContext _) => AppColors.purple;
  static bool _dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;
}

class AppTheme {
  static ThemeData get lightTheme => _build(Brightness.light);
  static ThemeData get darkTheme => _build(Brightness.dark);
  static ThemeData get theme => lightTheme;

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final textColor = isDark ? AppColors.darkPrimary : AppColors.primary;
    final mutedColor = isDark ? AppColors.darkMuted : AppColors.muted;
    final surfaceColor = isDark ? AppColors.darkSurface : AppColors.surface;
    final cardColor = isDark ? AppColors.darkCard : AppColors.card;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: brightness,
        surface: surfaceColor,
        primary: AppColors.accent,
        secondary: AppColors.teal,
        tertiary: AppColors.purple,
      ),
      scaffoldBackgroundColor: surfaceColor,
      cardColor: cardColor,
      dividerColor: textColor.withValues(alpha: 0.08),
      textTheme: GoogleFonts.dmSansTextTheme(
        isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
      ).copyWith(
        displayLarge: GoogleFonts.spaceGrotesk(
            fontSize: 28, fontWeight: FontWeight.w700, color: textColor),
        displayMedium: GoogleFonts.spaceGrotesk(
            fontSize: 22, fontWeight: FontWeight.w700, color: textColor),
        displaySmall: GoogleFonts.spaceGrotesk(
            fontSize: 18, fontWeight: FontWeight.w700, color: textColor),
        headlineMedium: GoogleFonts.spaceGrotesk(
            fontSize: 16, fontWeight: FontWeight.w600, color: textColor),
        titleMedium: GoogleFonts.dmSans(
            fontSize: 15, fontWeight: FontWeight.w500, color: textColor),
        bodyLarge: GoogleFonts.dmSans(
            fontSize: 14, fontWeight: FontWeight.w400, color: textColor),
        bodyMedium: GoogleFonts.dmSans(
            fontSize: 13, fontWeight: FontWeight.w400, color: mutedColor),
        bodySmall: GoogleFonts.dmSans(
            fontSize: 11, fontWeight: FontWeight.w400, color: mutedColor),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: surfaceColor,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        shadowColor: textColor.withValues(alpha: 0.06),
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: textColor),
        actionsIconTheme: IconThemeData(color: textColor),
        titleTextStyle: GoogleFonts.spaceGrotesk(
            fontSize: 18, fontWeight: FontWeight.w700, color: textColor),
        systemOverlayStyle: isDark
            ? const SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.light,
                systemNavigationBarColor: Color(0xFF1A1A2E),
              )
            : const SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.dark,
                systemNavigationBarColor: Color(0xFFFFFFFF),
              ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          elevation: 0,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle:
              GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.accent,
          textStyle:
              GoogleFonts.dmSans(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: textColor.withValues(alpha: 0.1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: textColor.withValues(alpha: 0.1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.red, width: 1.5),
        ),
        labelStyle: GoogleFonts.dmSans(fontSize: 12, color: mutedColor),
        hintStyle: GoogleFonts.dmSans(fontSize: 14, color: mutedColor),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
