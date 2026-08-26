import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_urls.dart';
import '../auth/auth_service.dart';
import '../auth/user_profile_service.dart';
import '../models/user_profile.dart';

class _AppLink {
  const _AppLink(this.label, this.url);
  final String label;
  final String url;
}

/// Mirrors `libs/auth/src/lib/access-denied/access-denied.component.ts` —
/// [appName] is the only per-app customization; the "try one of your other
/// apps" list is derived from the signed-in user's actual roles, same as
/// the Angular version.
class AccessDeniedScreen extends ConsumerWidget {
  const AccessDeniedScreen({required this.appName, super.key});

  final String appName;

  List<_AppLink> _matchingApps(List<UserRole> roles) {
    final links = <_AppLink>[];
    if (roles.contains(UserRole.physician) || roles.contains(UserRole.nurse)) {
      links.add(const _AppLink('Physician app', AppUrls.physician));
    }
    if (roles.contains(UserRole.ems)) {
      links.add(const _AppLink('EMS app', AppUrls.ems));
    }
    if (roles.contains(UserRole.admin) || roles.contains(UserRole.superAdmin)) {
      links.add(const _AppLink('Admin app', AppUrls.admin));
    }
    return links;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final matchingApps = _matchingApps(profile?.role ?? const []);
    // TODO(debug): temporary — see AuthService.signOut()'s own TODO(debug).
    // Confirms/denies whether the route guard ever sends a valid,
    // successfully-signed-in user here even briefly (this screen itself
    // never calls signOut() on its own — only the button below does — but
    // landing here at all before self-correcting would be its own real bug
    // worth knowing about).
    debugPrint(
      '[DIAG] AccessDeniedScreen: build() entered at ${DateTime.now()}, '
      'orgId=${profile?.organizationId} roles=${profile?.role}',
    );

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
                onPressed: () {
                  // TODO(debug): temporary — see AuthService.signOut()'s
                  // own TODO(debug).
                  debugPrint('[DIAG] AccessDeniedScreen: Log out button pressed at ${DateTime.now()}');
                  ref.read(authServiceProvider).signOut();
                },
                child: const Text('Log out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
