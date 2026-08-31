import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_urls.dart';
import '../auth/auth_service.dart';
import '../auth/user_profile_service.dart';

/// Mirrors `libs/auth/src/lib/access-denied/access-denied.component.ts` —
/// [appName] is the only per-app customization; the "try one of your other
/// apps" list is derived from the signed-in user's actual roles (see
/// [matchingAppLinks], shared with [LoginScreen]'s own wrong-app step),
/// same as the Angular version.
class AccessDeniedScreen extends ConsumerWidget {
  const AccessDeniedScreen({required this.appName, super.key});

  final String appName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final matchingApps = matchingAppLinks(profile?.role ?? const []);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Access denied', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(
                "Your account doesn't have access to the $appName app.",
                textAlign: TextAlign.center,
              ),
              if (matchingApps.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Text('Try one of your other apps:'),
                const SizedBox(height: 8),
                for (final app in matchingApps)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: OutlinedButton(
                      onPressed: () => launchUrl(Uri.parse(app.url)),
                      child: Text(app.label),
                    ),
                  ),
              ],
              const SizedBox(height: 20),
              TextButton(
                onPressed: () => ref.read(authServiceProvider).signOut(),
                child: const Text('Log out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
