import 'dart:async';

import 'package:google_fonts/google_fonts.dart';

/// Flutter's own auto-discovered suite-wide setup hook — runs once before
/// any test in this package, including every widget test that pumps the
/// real `buildLightTheme()`/`buildDarkTheme()` (both call `GoogleFonts.outfit(...)`).
/// Without this, `google_fonts` fires an un-awaited background font fetch
/// on first use — a real network call from inside `flutter test`, exactly
/// the non-hermetic, CI-hostile behavior every other exclusion/mock in
/// this repo exists to avoid. See TESTING.md for what was confirmed
/// empirically about the fallback behavior once fetching is disabled.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  return testMain();
}
