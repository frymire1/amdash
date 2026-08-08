import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';

final connectivityProvider = StreamProvider<List<ConnectivityResult>>((ref) {
  return Connectivity().onConnectivityChanged;
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
