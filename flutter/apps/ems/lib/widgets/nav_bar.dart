import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Mirrors `nav-bar.component.ts`/`.html`: brand, user-initials avatar,
/// sign-out button.
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

    return AppBar(
      title: const Text('AmDash'),
      centerTitle: true,
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: CircleAvatar(
            radius: 16,
            backgroundColor: initials.isEmpty ? AppColors.slate400 : AppColors.brand,
            child: initials.isEmpty
                ? const Icon(Icons.account_circle, color: Colors.white, size: 20)
                : Text(initials, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ),
        IconButton(
          onPressed: _loggingOut ? null : _logOut,
          tooltip: 'Log out',
          icon: _loggingOut
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.logout),
        ),
      ],
    );
  }
}
