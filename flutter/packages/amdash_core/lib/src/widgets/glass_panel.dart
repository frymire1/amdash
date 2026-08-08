import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Real backdrop-blur glass surface — reserved for hero surfaces (NavBar,
/// top stat/summary strips) rather than every card, to avoid blur cost on
/// long scrollable lists. List cards get the cheaper translucent-fill look
/// from the theme's `CardTheme` instead.
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.child, this.borderRadius, this.blurSigma = 14});

  final Widget child;
  final BorderRadius? borderRadius;
  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final radius = borderRadius ?? BorderRadius.circular(AppRadius.md);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: DecoratedBox(
          decoration: BoxDecoration(color: palette.glassSurface, borderRadius: radius, border: Border.all(color: palette.border)),
          child: child,
        ),
      ),
    );
  }
}
