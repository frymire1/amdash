import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum StatusPillKind { active, critical, done, warning, neutral }

/// Shared dot+label status pill — generalizes the pulsing "Tracking
/// Online" badge pattern (originally physician-only) into one themed
/// widget every app can use. [pulsing] is automatically suppressed when
/// the OS requests reduced motion (`MediaQuery.disableAnimations`),
/// regardless of what's passed in — mirrors the `prefers-reduced-motion`
/// handling in the approved mockup.
class StatusPill extends StatefulWidget {
  const StatusPill({super.key, required this.kind, required this.label, this.pulsing = false});

  final StatusPillKind kind;
  final String label;
  final bool pulsing;

  @override
  State<StatusPill> createState() => _StatusPillState();
}

// TickerProviderStateMixin, not SingleTickerProviderStateMixin — this
// State disposes and recreates its AnimationController whenever `pulsing`
// or OS-level reduced-motion toggles, and SingleTickerProviderStateMixin
// only ever permits vending one ticker for the entire State lifetime, even
// across dispose/recreate cycles.
class _StatusPillState extends State<StatusPill> with TickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncController();
  }

  @override
  void didUpdateWidget(covariant StatusPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncController();
  }

  void _syncController() {
    final shouldAnimate = widget.pulsing && !MediaQuery.of(context).disableAnimations;
    if (shouldAnimate && _controller == null) {
      _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    } else if (!shouldAnimate && _controller != null) {
      _controller!.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Color _colorFor(AppPalette palette) => switch (widget.kind) {
    StatusPillKind.active => palette.glow,
    StatusPillKind.critical => palette.critical,
    StatusPillKind.done => palette.success,
    StatusPillKind.warning => palette.warning,
    StatusPillKind.neutral => palette.border,
  };

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = _colorFor(palette);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadius.md - 2),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.label.toUpperCase(),
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: color),
          ),
          const SizedBox(width: 6),
          _Dot(color: color, controller: _controller),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.controller});

  final Color color;
  final AnimationController? controller;

  @override
  Widget build(BuildContext context) {
    if (controller == null) {
      return Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: color));
    }
    return AnimatedBuilder(
      animation: controller!,
      builder: (context, _) {
        final t = controller!.value;
        return Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: [BoxShadow(color: color.withValues(alpha: (0.6 * (1 - t)).clamp(0, 1)), spreadRadius: 6 * t)],
          ),
        );
      },
    );
  }
}
