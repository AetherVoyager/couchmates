import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';

/// Accent colors offered in Appearance. Periwinkle is the logo's colour.
const accentChoices = <(String, int)>[
  ('Periwinkle', 0xFF7C9CFF),
  ('Red', 0xFFE50914),
  ('Teal', 0xFF26A69A),
  ('Coral', 0xFFFF7A59),
  ('Amber', 0xFFFFB300),
  ('Rose', 0xFFE91E63),
  ('Violet', 0xFF9C27B0),
  ('Lime', 0xFF8BC34A),
];

/// The display face for headings and titles; body text stays the system font.
const displayFont = 'Bricolage Grotesque';

/// The night palette: indigo-black surfaces taken from the logo, in a few
/// steps, so artwork carries the colour.
abstract final class Cinema {
  static const background = Color(0xFF0D0E18);
  static const pane = Color(0xFF090A12);
  static const card = Color(0xFF181A2B);
  static const raised = Color(0xFF242740);
  static const muted = Color(0xFFAEB2CC);
  static const faint = Color(0xFF737896);
}

ThemeData couchmatesTheme({required Brightness brightness, int accent = 0xFF7C9CFF, bool black = false}) {
  final dark = brightness == Brightness.dark;
  final seeded = ColorScheme.fromSeed(seedColor: Color(accent), brightness: brightness);
  final bg = black ? Colors.black : Cinema.background;
  final onAccent = ThemeData.estimateBrightnessForColor(Color(accent)) == Brightness.dark
      ? Colors.white
      : const Color(0xFF0D0E18);
  final scheme = dark
      ? seeded.copyWith(
          // The exact accent, not a tone of it: a red should stay red.
          primary: Color(accent),
          onPrimary: onAccent,
          surface: bg,
          onSurface: Colors.white,
          onSurfaceVariant: Cinema.muted,
          surfaceContainerLowest: black ? Colors.black : Cinema.pane,
          surfaceContainerLow: const Color(0xFF121323),
          surfaceContainer: Cinema.card,
          surfaceContainerHigh: const Color(0xFF1E2034),
          surfaceContainerHighest: Cinema.raised,
          outline: const Color(0xFF4A4E6C),
          outlineVariant: const Color(0xFF2B2E47),
        )
      : seeded;
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  TextStyle? display(TextStyle? t, FontWeight w, [double spacing = 0]) =>
      t?.copyWith(fontFamily: displayFont, fontWeight: w, letterSpacing: spacing);
  final text = base.textTheme.copyWith(
    displayMedium: display(base.textTheme.displayMedium, FontWeight.w800, -1.2),
    displaySmall: display(base.textTheme.displaySmall, FontWeight.w800, -0.8),
    headlineMedium: display(base.textTheme.headlineMedium, FontWeight.w700, -0.4),
    headlineSmall: display(base.textTheme.headlineSmall, FontWeight.w700, -0.2),
    titleLarge: display(base.textTheme.titleLarge, FontWeight.w700, -0.2),
    titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
  );
  final panel = dark ? const Color(0xFF161828) : null;
  final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(color: scheme.surfaceContainer, elevation: 0, shape: rounded),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: rounded)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: rounded)),
    popupMenuTheme: PopupMenuThemeData(color: panel, shape: rounded),
    menuTheme: MenuThemeData(
      style: MenuStyle(backgroundColor: WidgetStatePropertyAll(panel), shape: WidgetStatePropertyAll(rounded)),
    ),
    dialogTheme: DialogThemeData(backgroundColor: panel),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: panel),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(color: const Color(0xFF2A2D48), borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.25)),
      radius: const Radius.circular(4),
    ),
  );
}

/// The light and dark themes and the mode for the current settings.
({ThemeData light, ThemeData dark, ThemeMode mode}) themesFor(AppSettings s) {
  final accent = s.get(Settings.accent);
  final choice = s.theme;
  return (
    light: couchmatesTheme(brightness: Brightness.light, accent: accent),
    dark: couchmatesTheme(brightness: Brightness.dark, accent: accent, black: choice == ThemeChoice.black),
    mode: switch (choice) {
      ThemeChoice.light => ThemeMode.light,
      ThemeChoice.system => ThemeMode.system,
      ThemeChoice.dark || ThemeChoice.black => ThemeMode.dark,
    },
  );
}

/// The widest the content gets on big screens.
const double maxContentWidth = 1400;

/// The side margin of full-width pages, wider on big windows.
double pageGutter(BuildContext context) => MediaQuery.sizeOf(context).width >= 1100 ? 48 : 24;
