import 'package:couchmates_core/couchmates_core.dart';
import 'package:flutter/material.dart';

/// Accent colors offered in Appearance.
const accentChoices = <(String, int)>[
  ('Red', 0xFFE50914),
  ('Periwinkle', 0xFF7C9CFF),
  ('Teal', 0xFF26A69A),
  ('Coral', 0xFFFF7A59),
  ('Amber', 0xFFFFB300),
  ('Rose', 0xFFE91E63),
  ('Violet', 0xFF9C27B0),
  ('Lime', 0xFF8BC34A),
];

/// The cinema palette: near-black surfaces in a few steps of grey, so artwork
/// carries the colour.
abstract final class Cinema {
  static const background = Color(0xFF141414);
  static const pane = Color(0xFF0C0C0C);
  static const card = Color(0xFF1F1F1F);
  static const raised = Color(0xFF2A2A2A);
  static const muted = Color(0xFFB3B3B3);
  static const faint = Color(0xFF808080);
}

ThemeData couchmatesTheme({required Brightness brightness, int accent = 0xFFE50914, bool black = false}) {
  final dark = brightness == Brightness.dark;
  final seeded = ColorScheme.fromSeed(seedColor: Color(accent), brightness: brightness);
  final bg = black ? Colors.black : Cinema.background;
  final scheme = dark
      ? seeded.copyWith(
          // The exact accent, not a tone of it: a red should stay red.
          primary: Color(accent),
          onPrimary: Colors.white,
          surface: bg,
          onSurface: Colors.white,
          onSurfaceVariant: Cinema.muted,
          surfaceContainerLowest: black ? Colors.black : Cinema.pane,
          surfaceContainerLow: const Color(0xFF181818),
          surfaceContainer: Cinema.card,
          surfaceContainerHigh: const Color(0xFF262626),
          surfaceContainerHighest: Cinema.raised,
          outline: const Color(0xFF4D4D4D),
          outlineVariant: const Color(0xFF333333),
        )
      : seeded;
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: brightness);
  final text = base.textTheme.copyWith(
    displaySmall: base.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
    headlineMedium: base.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
    headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
    titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
  );
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainer,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? const Color(0xFF1C1C1C) : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(dark ? const Color(0xFF1C1C1C) : null),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
      ),
    ),
    dialogTheme: DialogThemeData(backgroundColor: dark ? const Color(0xFF181818) : null),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: dark ? const Color(0xFF181818) : null),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(color: const Color(0xFF2F2F2F), borderRadius: BorderRadius.circular(4)),
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
