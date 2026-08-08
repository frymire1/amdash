import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// A fast, subtle fade used for every route in the app — GoRoute's default
/// (a ~300ms platform page transition) read as sluggish once routes are
/// wrapped in the retheme's glass/grid background; a short fade keeps
/// navigation feeling immediate without a jarring hard cut.
Page<void> fastFadePage(BuildContext context, GoRouterState state, Widget child) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 150),
    reverseTransitionDuration: const Duration(milliseconds: 120),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}
