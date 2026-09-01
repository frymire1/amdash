import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Mirrors `apps/admin/src/app/components/nav-bar/nav-bar.component.ts`/
/// `.html` — unlike EMS/physician's shared single-screen [NavBar], admin
/// needs real multi-page navigation, so this is admin-app-local: a
/// hamburger menu with role-conditional links (both sets of links show
/// for a dual-role account), centered "AmDash Admin" brand (the admin app
/// is the one app where the brand text differs from the shared "AmDash"),
/// and an avatar that opens a dropdown with Settings and Logout.
class AdminNavBar extends ConsumerStatefulWidget implements PreferredSizeWidget {
  const AdminNavBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  ConsumerState<AdminNavBar> createState() => _AdminNavBarState();
}

class _AdminNavBarState extends ConsumerState<AdminNavBar> {
  bool _loggingOut = false;

  Future<void> _logOut() async {
    setState(() => _loggingOut = true);
    try {
      await ref.read(authServiceProvider).signOut();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to log out. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final initials = profile?.initials ?? '';
    final isAdmin = profile?.hasRole(UserRole.admin) ?? false;
    final isSuperAdmin = profile?.hasRole(UserRole.superAdmin) ?? false;
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.palette;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      // See the matching comment in the shared NavBar — AppBar computes its
      // own status bar icon style by default, which can win over
      // AppBackground's AnnotatedRegion right where the status bar sits.
      systemOverlayStyle: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      flexibleSpace: const GlassPanel(borderRadius: BorderRadius.zero, child: SizedBox.expand()),
      leading: PopupMenuButton<String>(
        icon: const Icon(Icons.menu),
        onSelected: (route) => context.go(route),
        itemBuilder: (context) => [
          if (isAdmin) ...[
            const PopupMenuItem(value: '/users', child: Text('Users')),
            const PopupMenuItem(value: '/hospitals', child: Text('Hospitals')),
            const PopupMenuItem(value: '/settings', child: Text('Settings')),
            const PopupMenuItem(value: '/audit-log', child: Text('Audit Log')),
          ],
          if (isSuperAdmin) const PopupMenuItem(value: '/organizations', child: Text('Organizations')),
        ],
      ),
      // Logo + wordmark centered together as one unit — see the shared
      // NavBar for the mainAxisSize.min + centerTitle reasoning.
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // See the shared NavBar for why cacheWidth/Height — decode the
          // 1024px source down to ~120px once rather than crushing it to
          // 40px at paint time, which aliases on low-DPI web.
          Image.asset(
            'assets/logo.png',
            package: 'amdash_core',
            height: 40,
            width: 40,
            cacheWidth: 120,
            cacheHeight: 120,
            filterQuality: FilterQuality.medium,
          ),
          const SizedBox(width: 3),
          const Text('AmDash Admin'),
        ],
      ),
      centerTitle: true,
      actions: [
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 16),
          child: PopupMenuButton<String>(
            tooltip: 'Account',
            enabled: !_loggingOut,
            onSelected: (value) {
              if (value == 'settings') {
                context.push('/user-settings');
              } else if (value == 'logout') {
                _logOut();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'settings', child: Text('Settings')),
              PopupMenuItem(value: 'logout', child: Text('Logout')),
            ],
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: palette.glow.withValues(alpha: 0.45), blurRadius: 12)],
              ),
              child: _loggingOut
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : CircleAvatar(
                      radius: 16,
                      backgroundColor: initials.isEmpty ? colorScheme.surfaceContainerHighest : colorScheme.primary,
                      child: initials.isEmpty
                          ? Icon(Icons.account_circle, color: colorScheme.onSurfaceVariant, size: 20)
                          : Text(initials, style: TextStyle(color: colorScheme.onPrimary, fontSize: 13)),
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
