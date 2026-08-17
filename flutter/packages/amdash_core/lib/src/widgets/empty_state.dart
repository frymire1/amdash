import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Which vector illustration to draw. `chartPulse` (clipboard + an active
/// pulse line) is used for the physician desktop viewer pane when nothing
/// is selected; `routePing` (map pin + radar sweep + dashed route) is the
/// general-purpose one, used everywhere else a list/dashboard has nothing
/// to show — patients, users, hospitals, organizations alike.
enum EmptyStateGraphic { chartPulse, routePing }

/// Small vector illustration for wherever a list/dashboard has nothing to
/// show. Drawn with [CustomPainter] rather than a raster asset, so it stays
/// crisp at any size/DPI and themes itself automatically via [AppPalette] —
/// no separate light/dark image to ship or keep in sync.
class EmptyStateIllustration extends StatelessWidget {
  const EmptyStateIllustration({super.key, this.graphic = EmptyStateGraphic.routePing, this.size = 96});

  final EmptyStateGraphic graphic;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: switch (graphic) {
          EmptyStateGraphic.chartPulse => _ChartPulsePainter(
            structure: onSurfaceVariant.withValues(alpha: 0.55),
            rows: onSurfaceVariant.withValues(alpha: 0.28),
            accent: palette.glow,
          ),
          EmptyStateGraphic.routePing => _RoutePingPainter(
            route: onSurfaceVariant.withValues(alpha: 0.32),
            accent: palette.glow,
          ),
        },
      ),
    );
  }
}

class _ChartPulsePainter extends CustomPainter {
  _ChartPulsePainter({required this.structure, required this.rows, required this.accent});

  final Color structure;
  final Color rows;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Clipboard outline.
    final board = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.14, h * 0.12, w * 0.72, h * 0.78),
      Radius.circular(w * 0.09),
    );
    canvas.drawRRect(
      board,
      Paint()
        ..color = structure
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.035,
    );

    // Clip tab at the top.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(w * 0.5, h * 0.12), width: w * 0.26, height: h * 0.07),
        Radius.circular(w * 0.025),
      ),
      Paint()..color = structure,
    );

    // Empty list rows near the bottom.
    final rowPaint = Paint()
      ..color = rows
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.028
      ..strokeCap = StrokeCap.round;
    for (final fraction in [0.63, 0.73, 0.83]) {
      canvas.drawLine(Offset(w * 0.30, h * fraction), Offset(w * 0.70, h * fraction), rowPaint);
    }

    // Pulse line with a soft glow behind it, centered in the upper half —
    // an active beat, deliberately not a flat line, to avoid reading as a
    // flatline in a healthcare app.
    final pulse = _pulsePath(w, h);
    canvas.drawPath(
      pulse,
      Paint()
        ..color = accent.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.09
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.05),
    );
    canvas.drawPath(
      pulse,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.04
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  Path _pulsePath(double w, double h) {
    final y = h * 0.44;
    return Path()
      ..moveTo(w * 0.26, y)
      ..lineTo(w * 0.38, y)
      ..lineTo(w * 0.44, y - h * 0.15)
      ..lineTo(w * 0.51, y + h * 0.19)
      ..lineTo(w * 0.58, y - h * 0.09)
      ..lineTo(w * 0.64, y)
      ..lineTo(w * 0.74, y);
  }

  @override
  bool shouldRepaint(covariant _ChartPulsePainter oldDelegate) =>
      structure != oldDelegate.structure || rows != oldDelegate.rows || accent != oldDelegate.accent;
}

class _RoutePingPainter extends CustomPainter {
  _RoutePingPainter({required this.route, required this.accent});

  final Color route;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final center = Offset(w * 0.5, h * 0.44);

    // Radar sweep rings behind the pin.
    canvas.drawCircle(
      center,
      w * 0.31,
      Paint()
        ..color = accent.withValues(alpha: 0.16)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.02,
    );
    canvas.drawCircle(
      center,
      w * 0.21,
      Paint()
        ..color = accent.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.02,
    );

    // A dashed route trailing off below the pin.
    final routePath = Path()
      ..moveTo(w * 0.14, h * 0.82)
      ..quadraticBezierTo(w * 0.30, h * 0.68, w * 0.42, h * 0.73)
      ..quadraticBezierTo(w * 0.55, h * 0.79, w * 0.68, h * 0.65);
    _drawDashed(canvas, routePath, route, w * 0.026, dashWidth: w * 0.022, dashGap: w * 0.045);

    // Pin body.
    final pinPaint = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.038
      ..strokeJoin = StrokeJoin.round;
    final pin = Path()
      ..moveTo(w * 0.5, h * 0.21)
      ..cubicTo(w * 0.40, h * 0.21, w * 0.315, h * 0.29, w * 0.315, h * 0.39)
      ..cubicTo(w * 0.315, h * 0.52, w * 0.5, h * 0.70, w * 0.5, h * 0.70)
      ..cubicTo(w * 0.5, h * 0.70, w * 0.685, h * 0.52, w * 0.685, h * 0.39)
      ..cubicTo(w * 0.685, h * 0.29, w * 0.60, h * 0.21, w * 0.5, h * 0.21)
      ..close();
    canvas.drawPath(pin, pinPaint);
    canvas.drawCircle(Offset(w * 0.5, h * 0.385), w * 0.067, Paint()..color = accent);
  }

  void _drawDashed(
    Canvas canvas,
    Path path,
    Color color,
    double strokeWidth, {
    required double dashWidth,
    required double dashGap,
  }) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + dashWidth;
        canvas.drawPath(metric.extractPath(distance, next.clamp(0, metric.length)), paint);
        distance = next + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RoutePingPainter oldDelegate) =>
      route != oldDelegate.route || accent != oldDelegate.accent;
}

/// Illustration + title + subtitle — the standard "nothing here" layout
/// shared by every list/dashboard/viewer-pane across the apps (patient
/// lists, the EMS dashboard, and admin's users/hospitals/organizations
/// tables alike). Aligned to the top of the available space by default (not
/// vertically centered) so it sits just under whatever heading/filter text
/// precedes it rather than floating in the true middle of a tall pane.
/// Defaults to [EmptyStateGraphic.routePing] since that's the more common of
/// the two placements (list/dashboard empty states outnumber the single
/// desktop viewer-pane spot that uses `chartPulse`).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.graphic = EmptyStateGraphic.routePing,
    this.centered = false,
  });

  final String title;
  final String? subtitle;
  final EmptyStateGraphic graphic;

  /// Vertically centers the illustration/title/subtitle instead of the
  /// default top-alignment — for the rare spot (physician's `PatientViewer`
  /// "select a patient" placeholder) with no heading/filter text above it to
  /// sit under, where top-alignment just strands it near the top of an
  /// otherwise-empty pane.
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;
    return Align(
      alignment: centered ? Alignment.center : Alignment.topCenter,
      child: Padding(
        // Top-aligned case: 75px top gap puts the illustration a fixed
        // distance below the heading/subtitle text above it instead of
        // drifting to the middle of whatever space happens to be available.
        // Centered case: no heading to sit under, so plain even padding.
        padding: centered ? const EdgeInsets.all(24) : const EdgeInsets.fromLTRB(24, 75, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            EmptyStateIllustration(graphic: graphic),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w600, color: onSurfaceVariant),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
