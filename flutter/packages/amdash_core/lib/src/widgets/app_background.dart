import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Wraps screen content with the retheme's signature subtle technical grid
/// + soft accent glow, matching the approved Arctic Cyan mockup's
/// `.app-shell` background. Painted once behind the whole subtree (not
/// per-card), so it's cheap regardless of how much content scrolls inside.
///
/// Also sets the system status bar's icon brightness to match the current
/// theme — nothing in the app did this before, so the OS default (light/
/// white icons) was used regardless of theme, leaving battery/signal/
/// notification icons invisible against light mode's light background.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: DecoratedBox(
        decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor),
        child: CustomPaint(
          painter: _GridPainter(gridLine: palette.gridLine, glow: palette.glow),
          child: child,
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.gridLine, required this.glow});

  final Color gridLine;
  final Color glow;

  static const double _spacing = 32;

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = gridLine
      ..strokeWidth = 1;
    for (double x = 0; x <= size.width; x += _spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }
    for (double y = 0; y <= size.height; y += _spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }

    final glowPaint = Paint()
      ..shader = RadialGradient(colors: [glow.withValues(alpha: 0.14), glow.withValues(alpha: 0)]).createShader(
        Rect.fromCircle(center: Offset(size.width * 0.85, 0), radius: size.width * 0.55),
      );
    canvas.drawRect(Offset.zero & size, glowPaint);
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) => oldDelegate.gridLine != gridLine || oldDelegate.glow != glow;
}
