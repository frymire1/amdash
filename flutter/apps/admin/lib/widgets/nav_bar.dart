import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Mirrors `apps/admin/src/app/components/nav-bar/nav-bar.component.ts`/
/// `.html` — unlike EMS/physician's shared single-screen [NavBar], admin
/// needs real multi-page navigation, so this is admin-app-local: a
/// hamburger menu with role-conditional links (both sets of links show
/// for a dual-role account), centered "AmDash Admin" brand (the admin app
/// is the one app where the brand text differs from the shared "AmDash"),
/// avatar, and logout.
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

    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      flexibleSpace: const GlassPanel(borderRadius: BorderRadius.zero, child: SizedBox.expand()),
      leading: PopupMenuButton<String>(
        icon: const Icon(Icons.menu),
        onSelected: (route) => context.go(route),
        itemBuilder: (context) => [
          if (isAdmin) ...[
            const PopupMenuItem(value: '/users', child: Text('Users')),
            const PopupMenuItem(value: '/hospitals', child: Text('Hospitals')),
            const PopupMenuItem(value: '/settings', child: Text('Settings')),
          ],
          if (isSuperAdmin) const PopupMenuItem(value: '/organizations', child: Text('Organizations')),
        ],
      ),
      title: const Text('AmDash Admin'),
      centerTitle: true,
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => context.push('/user-settings'),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: palette.glow.withValues(alpha: 0.45), blurRadius: 12)],
              ),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: initials.isEmpty ? colorScheme.surfaceContainerHighest : colorScheme.primary,
                child: initials.isEmpty
                    ? Icon(Icons.account_circle, color: colorScheme.onSurfaceVariant, size: 20)
                    : Text(initials, style: TextStyle(color: colorScheme.onPrimary, fontSize: 13)),
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: _loggingOut ? null : _logOut,
          tooltip: 'Log out',
          icon: _loggingOut
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.logout),
        ),
      ],
    );
  }
}
