import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Centralized theme tokens for Shattlecoach.
///
/// Palette derives from the proposal logo: court green primary, shuttlecock
/// yellow secondary, magenta reserved for alerts. Edit values here — do not
/// hardcode hex elsewhere.
class AppPalette {
  AppPalette._();

  // Light
  static const Color primary = Color(0xFF1F8A3B);
  static const Color secondary = Color(0xFFF4D32A);
  static const Color accent = Color(0xFFE91E63);
  static const Color surface = Color(0xFFF7F8F5);
  static const Color background = Color(0xFFFFFFFF);
  static const Color text = Color(0xFF0E1411);
  static const Color textMuted = Color(0xFF5C6660);

  // Dark
  static const Color darkPrimary = Color(0xFF58C97A);
  static const Color darkSecondary = Color(0xFFF4D32A);
  static const Color darkAccent = Color(0xFFFF4F8A);
  static const Color darkSurface = Color(0xFF16201A);
  static const Color darkBackground = Color(0xFF0E1411);
  static const Color darkText = Color(0xFFE6EAE7);
  static const Color darkTextMuted = Color(0xFF98A29D);

  // Court tones (used in custom paint backgrounds, AI Coach screen, etc.)
  static const Color courtLine = Color(0xFFFFFFFF);
  static const Color courtSurface = Color(0xFF2F9E4F);
}

class AppTheme {
  AppTheme._();

  static ThemeData get light => _build(_lightScheme, Brightness.light);
  static ThemeData get dark => _build(_darkScheme, Brightness.dark);

  static const ColorScheme _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppPalette.primary,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFC8EBD2),
    onPrimaryContainer: Color(0xFF06351A),
    secondary: AppPalette.secondary,
    onSecondary: Color(0xFF1A1A1A),
    secondaryContainer: Color(0xFFFFF2A8),
    onSecondaryContainer: Color(0xFF3D3300),
    tertiary: AppPalette.accent,
    onTertiary: Colors.white,
    error: AppPalette.accent,
    onError: Colors.white,
    surface: AppPalette.surface,
    onSurface: AppPalette.text,
    surfaceContainerHighest: Color(0xFFE8ECE6),
    onSurfaceVariant: AppPalette.textMuted,
    outline: Color(0xFFCCD2CD),
    outlineVariant: Color(0xFFE3E7E2),
    shadow: Colors.black,
    scrim: Colors.black54,
    inverseSurface: AppPalette.darkBackground,
    onInverseSurface: AppPalette.darkText,
    inversePrimary: AppPalette.darkPrimary,
  );

  static const ColorScheme _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppPalette.darkPrimary,
    onPrimary: Color(0xFF06351A),
    primaryContainer: Color(0xFF1A5A33),
    onPrimaryContainer: Color(0xFFC8EBD2),
    secondary: AppPalette.darkSecondary,
    onSecondary: Color(0xFF1A1A1A),
    secondaryContainer: Color(0xFF5C4E00),
    onSecondaryContainer: Color(0xFFFFF2A8),
    tertiary: AppPalette.darkAccent,
    onTertiary: Colors.white,
    error: AppPalette.darkAccent,
    onError: Colors.white,
    surface: AppPalette.darkSurface,
    onSurface: AppPalette.darkText,
    surfaceContainerHighest: Color(0xFF1F2A23),
    onSurfaceVariant: AppPalette.darkTextMuted,
    outline: Color(0xFF3A453E),
    outlineVariant: Color(0xFF263028),
    shadow: Colors.black,
    scrim: Colors.black87,
    inverseSurface: AppPalette.surface,
    onInverseSurface: AppPalette.text,
    inversePrimary: AppPalette.primary,
  );

  static ThemeData _build(ColorScheme scheme, Brightness brightness) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
    );

    return base.copyWith(
      textTheme: GoogleFonts.interTextTheme(
        base.textTheme,
      ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return GoogleFonts.inter(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
            size: 24,
          );
        }),
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          side: BorderSide(color: scheme.outline),
          textStyle: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
