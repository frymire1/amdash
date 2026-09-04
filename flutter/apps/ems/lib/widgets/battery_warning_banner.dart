import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/battery_watch_service.dart';

/// Same shape/placement as amdash_core's own `OfflineBanner` — a full-width
/// strip above the main content, driven by a real provider rather than a
/// one-time check. `palette.critical` (not `.warning`, unlike
/// `OfflineBanner`) — a device that may die mid-transport is more urgent
/// than "some features may not work".
class BatteryWarningBanner extends ConsumerWidget {
  const BatteryWarningBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLow = ref.watch(batteryWatchProvider);
    if (!isLow) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      color: context.palette.critical,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: const Text(
        'Battery low — tracking may stop soon. Plug in or hand off if possible.',
        style: TextStyle(color: Colors.black87, fontSize: 13),
        textAlign: TextAlign.center,
      ),
    );
  }
}
