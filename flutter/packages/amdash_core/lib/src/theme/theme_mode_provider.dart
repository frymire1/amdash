import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'amdash_theme_mode';

/// Persisted across app restarts via `SharedPreferences` — shared by all
/// three apps rather than reimplemented per-app, same reasoning as the
/// rest of `amdash_core`'s theme system. Defaults to following the OS
/// setting until a user explicitly picks light/dark from User Settings.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    final mode = ThemeMode.values.firstWhere((m) => m.name == stored, orElse: () => ThemeMode.system);
    if (mode != state) state = mode;
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
