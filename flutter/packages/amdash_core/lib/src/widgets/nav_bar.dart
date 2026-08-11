import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_service.dart';
import '../auth/user_profile_service.dart';
import '../theme/app_theme.dart';
import 'glass_panel.dart';

/// Mirrors `nav-bar.component.ts`/`.html`: brand and a user-initials avatar
/// that opens a dropdown with Settings and Logout, rather than separate
/// tap-to-navigate and sign-out controls. Shared across every app — the
/// brand text is always "AmDash", never per-app. Renders as a glass panel
/// (real backdrop blur) per the Arctic Cyan retheme, since it's one of the
/// few "hero" surfaces that gets real blur rather than the cheaper
/// translucent-card look.
class NavBar extends ConsumerStatefulWidget implements PreferredSizeWidget {
  const NavBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  ConsumerState<NavBar> createState() => _NavBarState();
}

class _NavBarState extends ConsumerState<NavBar> {
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
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.palette;

    return AppBar(
      title: const Text('AmDash'),
      centerTitle: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      flexibleSpace: const GlassPanel(borderRadius: BorderRadius.zero, child: SizedBox.expand()),
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
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
