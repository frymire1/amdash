import 'package:flutter/material.dart';

/// Consolidated design tokens for AmDash. The Angular apps never defined a
/// real token system — every color was a hardcoded hex repeated ad hoc per
/// component, with ~15 near-duplicate grays doing the job of what should
/// have been one slate scale (see the migration inventory). Defined once,
/// here, rather than reproduced literally.
abstract final class AppColors {
  /// Primary brand blue — nav bars, primary buttons, links.
  static const brand = Color(0xFF2563EB);
  static const brandDark = Color(0xFF1D4ED8);

  /// Secondary accent used specifically for live-tracking/vitals UI in the
  /// Angular apps (`#0284c7`) — kept distinct from [brand] rather than
  /// merged, since it's a deliberately different visual signal (tracking
  /// state vs. primary actions).
  static const trackingAccent = Color(0xFF0284C7);

  static const success = Color(0xFF16A34A);
  static const danger = Color(0xFFDC2626);
  static const warning = Color(0xFF7C2D12);

  /// One slate scale, replacing the Angular apps' ~10 near-duplicate grays
  /// (#333/#555/#6f7280/#64748b/#475569/#334155/#1e293b/#94a3b8/#999/
  /// #212529).
  static const slate900 = Color(0xFF1E293B);
  static const slate700 = Color(0xFF334155);
  static const slate500 = Color(0xFF64748B);
  static const slate400 = Color(0xFF94A3B8);
  static const slate200 = Color(0xFFE2E8F0);
  static const slate100 = Color(0xFFF1F5F9);
}

ThemeData buildAppTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppColors.brand,
    primary: AppColors.brand,
    error: AppColors.danger,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.slate100,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.slate900,
      foregroundColor: Colors.white,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.brand,
        foregroundColor: Colors.white,
      ),
    ),
  );
}
