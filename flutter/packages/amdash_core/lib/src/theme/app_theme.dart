import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// One consistent corner radius everywhere (cards, buttons, inputs, chips)
/// rather than a scale — matches the approved "Arctic Cyan" mockup, which
/// used a single radius across the whole system.
abstract final class AppRadius {
  static const double md = 7;
}

/// Consolidated design tokens for AmDash. Retuned to the Arctic Cyan
/// palette approved for the app-wide retheme (previously the original
/// brand blue). Kept as static consts — for the (larger) set of screens
/// that reference these directly rather than through [AppPalette], the
/// values here define what they'll look like; only widgets touched in the
/// retheme itself use [AppPalette] for brightness-aware theming.
abstract final class AppColors {
  /// Primary brand accent — nav bars, primary buttons, links, glow effects.
  static const brand = Color(0xFF12A7B5);
  static const brandDark = Color(0xFF0C8F87);

  /// Secondary accent used specifically for live-tracking/vitals UI — kept
  /// distinct from [brand] rather than merged, since it's a deliberately
  /// different visual signal (tracking state vs. primary actions).
  static const trackingAccent = Color(0xFF0EA5A0);

  static const success = Color(0xFF3F8F5C);
  static const danger = Color(0xFFC34B3F);
  static const warning = Color(0xFFB9832E);

  /// One slate scale, nudged toward a cool teal-grey to sit comfortably
  /// against the new accent rather than the old warm blue-grey.
  static const slate900 = Color(0xFF16211F);
  static const slate700 = Color(0xFF2E3B39);
  static const slate500 = Color(0xFF5E7A7D);
  static const slate400 = Color(0xFF8AA3A0);
  static const slate200 = Color(0xFFD7E6E4);
  static const slate100 = Color(0xFFEAF6F7);
}

/// Design tokens the stock [ColorScheme] has no slot for (accent/onAccent
/// already live on `ColorScheme.primary`/`onPrimary` and are used via
/// those directly). Registered as a [ThemeExtension] on both
/// [buildLightTheme]/[buildDarkTheme] so
/// `Theme.of(context).extension<AppPalette>()!` — or the [AppPaletteX]
/// shortcut, `context.palette` — resolves the right values for whichever
/// brightness is active, without call sites branching on
/// `Theme.of(context).brightness` themselves.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.glassSurface,
    required this.border,
    required this.gridLine,
    required this.glow,
    required this.success,
    required this.warning,
    required this.critical,
  });

  /// Translucent card/panel fill — the "cheap glass" look used for lists
  /// and inputs (real `BackdropFilter` blur is reserved for hero surfaces,
  /// see `GlassPanel`).
  final Color glassSurface;
  final Color border;

  /// Faint grid-line color painted behind screen content by
  /// `AppBackground`.
  final Color gridLine;

  /// Base color for glow `BoxShadow`s (avatar, active nav, critical
  /// cards, pulsing status dots).
  final Color glow;

  final Color success;
  final Color warning;
  final Color critical;

  static const light = AppPalette(
    glassSurface: Color(0xA3FFFFFF), // rgba(255,255,255,.64)
    border: Color(0x24123A38), // rgba(15,45,42,.14)
    gridLine: Color(0x0A12A7B5),
    glow: AppColors.brand,
    success: AppColors.success,
    warning: AppColors.warning,
    critical: AppColors.danger,
  );

  static const dark = AppPalette(
    glassSurface: Color(0x8C152524), // rgba(21,37,34,.55)
    border: Color(0x2933D6E6), // rgba(45,225,211,.16)
    gridLine: Color(0x1433D6E6),
    glow: Color(0xFF33D6E6),
    success: Color(0xFF4CD97B),
    warning: Color(0xFFFFC15E),
    critical: Color(0xFFFF6B6B),
  );

  @override
  AppPalette copyWith({
    Color? glassSurface,
    Color? border,
    Color? gridLine,
    Color? glow,
    Color? success,
    Color? warning,
    Color? critical,
  }) {
    return AppPalette(
      glassSurface: glassSurface ?? this.glassSurface,
      border: border ?? this.border,
      gridLine: gridLine ?? this.gridLine,
      glow: glow ?? this.glow,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      critical: critical ?? this.critical,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      glassSurface: Color.lerp(glassSurface, other.glassSurface, t)!,
      border: Color.lerp(border, other.border, t)!,
      gridLine: Color.lerp(gridLine, other.gridLine, t)!,
      glow: Color.lerp(glow, other.glow, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      critical: Color.lerp(critical, other.critical, t)!,
    );
  }
}

extension AppPaletteX on BuildContext {
  AppPalette get palette => Theme.of(this).extension<AppPalette>() ?? AppPalette.light;
}

ThemeData buildLightTheme() => _buildTheme(brightness: Brightness.light);

ThemeData buildDarkTheme() => _buildTheme(brightness: Brightness.dark);

ThemeData _buildTheme({required Brightness brightness}) {
  final isDark = brightness == Brightness.dark;
  final palette = isDark ? AppPalette.dark : AppPalette.light;

  final background = isDark ? const Color(0xFF071618) : const Color(0xFFEAF6F7);
  final surface = isDark ? const Color(0xFF0F201E) : Colors.white;
  final onSurface = isDark ? const Color(0xFFE3F6F3) : const Color(0xFF122225);
  final accent = isDark ? const Color(0xFF33D6E6) : AppColors.brand;
  final onAccent = isDark ? const Color(0xFF06201D) : Colors.white;

  final colorScheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
    primary: accent,
    onPrimary: onAccent,
    surface: surface,
    onSurface: onSurface,
    error: palette.critical,
  );

  final baseTextTheme = (isDark ? ThemeData.dark() : ThemeData.light()).textTheme;

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: background,
    textTheme: _headingTextTheme(baseTextTheme, onSurface),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: onSurface,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: GoogleFonts.outfit(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: onSurface),
    ),
    cardTheme: CardThemeData(
      color: palette.glassSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: palette.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.glassSurface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md), borderSide: BorderSide(color: palette.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md), borderSide: BorderSide(color: palette.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md), borderSide: BorderSide(color: accent, width: 1.5)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onAccent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onAccent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: accent,
        side: BorderSide(color: palette.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
      ),
    ),
    extensions: [palette],
  );
}

TextTheme _headingTextTheme(TextTheme base, Color color) {
  TextStyle? heading(TextStyle? style, double tracking) {
    if (style == null) return null;
    return GoogleFonts.outfit(textStyle: style, fontWeight: FontWeight.w700, letterSpacing: tracking, color: color);
  }

  return base.copyWith(
    displayLarge: heading(base.displayLarge, 0.5),
    displayMedium: heading(base.displayMedium, 0.5),
    displaySmall: heading(base.displaySmall, 0.4),
    headlineLarge: heading(base.headlineLarge, 0.4),
    headlineMedium: heading(base.headlineMedium, 0.4),
    headlineSmall: heading(base.headlineSmall, 0.3),
    titleLarge: heading(base.titleLarge, 0.3),
    titleMedium: heading(base.titleMedium, 0.2),
    titleSmall: heading(base.titleSmall, 0.2),
  );
}
