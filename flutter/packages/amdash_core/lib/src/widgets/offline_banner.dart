import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';

final connectivityProvider = StreamProvider<List<ConnectivityResult>>((ref) {
  // coverage:ignore-start
  // Real platform-channel call (connectivity_plus's EventChannel) —
  // confirmed for real via a throwaway probe test that
  // Connectivity().onConnectivityChanged never emits/errors/completes at
  // all in a plain Dart VM test (no platform bindings for any real
  // target); the probe's own 3s .timeout() didn't even save it — the
  // pending EventChannel subscription hung the whole test past its
  // container's disposal. Every real test overrides connectivityProvider
  // itself instead (see offline_banner_test.dart) — same category as
  // fhir_export_service.dart's FileSaver call and mfa_service.dart's
  // TotpMultiFactorGenerator statics; no DI seam fixes this since the
  // plugin has no fake-implementation package.
  return Connectivity().onConnectivityChanged;
  // coverage:ignore-end
});

final isOfflineProvider = Provider<bool>((ref) {
  final connectivity = ref.watch(connectivityProvider);
  return connectivity.maybeWhen(
    data: (results) => results.isNotEmpty && results.every((r) => r == ConnectivityResult.none),
    orElse: () => false,
  );
});

/// Mirrors `libs/auth/src/lib/offline-banner/offline-banner.component.ts`:
/// rendered once above the main content in every app shell, driven by real
/// connectivity events rather than a one-time check.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOffline = ref.watch(isOfflineProvider);
    if (!isOffline) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      color: context.palette.warning,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: const Text(
        'You are offline. Some features may not work.',
        style: TextStyle(color: Colors.black87, fontSize: 13),
        textAlign: TextAlign.center,
      ),
    );
  }
}
