import 'package:flutter/material.dart';

import 'nav_bar.dart';

/// Shared layout for every admin management screen — mirrors the
/// `max-width: 960px` centered container repeated (copy-pasted, per the
/// Angular source) across `user-management`/`hospital-management`/
/// `organization-management`/`organization-settings`'s `.scss` files.
class AdminPage extends StatelessWidget {
  const AdminPage({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const AdminNavBar(),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ),
      ),
    );
  }
}

/// A form/table card — mirrors the repeated white rounded-12px
/// `box-shadow: 0 2px 8px rgba(0,0,0,0.1)` card styling.
class AdminCard extends StatelessWidget {
  const AdminCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(padding: const EdgeInsets.all(20), child: child),
    );
  }
}

/// Mirrors the `.form-message--success`/`--error` inline text pattern
/// repeated across all 4 page components — no confirm/error dialogs
/// anywhere in the Angular admin app, just inline text under the form.
class FormMessage extends StatelessWidget {
  const FormMessage({required this.text, required this.isError, super.key});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: TextStyle(
          color: isError ? Theme.of(context).colorScheme.error : Colors.green,
        ),
      ),
    );
  }
}
