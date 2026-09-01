import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

// Patrol's own `.tap()`/`.enterText()`/`.waitUntilVisible()` require a
// widget to pass its hit-testable check, which — verified manually against
// a real browser, where every one of these interactions works fine —
// proved intermittently unreliable against this app family's Material
// overlays (dropdown menus, autocomplete option lists) and, at least once,
// an entirely ordinary always-visible button, across all three apps this
// package serves. Raw WidgetTester actions (only require the widget to
// exist, then simulate the interaction at its computed center) don't have
// this problem, so every helper below goes through those instead of
// Patrol's own high-level `$(...)` API.

/// Taps [finder] via the raw [WidgetTester] rather than Patrol's own
/// `$(...).tap()` — see this file's header comment for why.
///
/// `ensureVisible` is best-effort (its own failure is swallowed, not
/// rethrown) rather than required to succeed first: confirmed for real on
/// EMS's own screens that `ensureVisible` can itself throw ("Bad state: No
/// element" on a definitely-present widget) when a Riverpod watch rebuilds
/// the tree mid-scroll — most of this package's screens don't hit that,
/// but swallowing the failure costs nothing when `ensureVisible` would
/// have succeeded anyway, and is exactly what's needed on the screens that
/// do. Scrolling a page tall enough to need it is still attempted first;
/// this only means a failed *attempt* doesn't block the tap that follows.
Future<void> tapFinder(PatrolIntegrationTester $, Finder finder) async {
  try {
    await $.tester.ensureVisible(finder);
  } catch (_) {
    // Best-effort — see this function's own doc comment.
  }
  await $.pump(const Duration(milliseconds: 200));
  await $.tester.tap(finder);
  await $.pump(const Duration(milliseconds: 400));
}

Future<void> tapText(PatrolIntegrationTester $, String text) => tapFinder($, find.text(text));

Future<void> tapKey(PatrolIntegrationTester $, String key) => tapFinder($, find.byKey(Key(key)));

Future<void> tapIcon(PatrolIntegrationTester $, IconData icon) => tapFinder($, find.byIcon(icon).first);

/// Enters [text] into the [index]-th `TextField` via the raw
/// [WidgetTester] rather than Patrol's own `$(TextField).at(index)
/// .enterText()` — same hit-testable-check unreliability as [tapFinder]
/// (see this file's header comment).
///
/// Waits for the field to exist at all before touching it — not just a
/// fixed short pump: confirmed for real (on more than one app in this
/// family) that a raw `enterText` with no existence check threw a bare
/// `RangeError` when called right after a route transition whose
/// `TextField` hadn't mounted yet, even though the *screen* had already
/// visibly changed (e.g. new title text present). Patrol's own high-level
/// `.enterText()` waits up to 10s before acting; this loop is that same
/// safety net without going through Patrol's own hit-testable check.
Future<void> enterTextAt(PatrolIntegrationTester $, int index, String text) async {
  for (var i = 0; i < 20; i++) {
    if (find.byType(TextField).evaluate().length > index) break;
    await $.pump(const Duration(milliseconds: 200));
  }
  final finder = find.byType(TextField).at(index);
  try {
    await $.tester.ensureVisible(finder);
  } catch (_) {
    // Best-effort — see tapFinder's own doc comment.
  }
  await $.pump(const Duration(milliseconds: 200));
  await $.tester.enterText(finder, text);
  await $.pump(const Duration(milliseconds: 400));
}

/// Polls with fixed pumps rather than a one-shot wait — network round
/// trips (Cloud Function calls, Firestore writes, listener updates) don't
/// always land inside a single short pump.
Future<void> pumpUntil(
  PatrolIntegrationTester $,
  bool Function() condition, {
  int maxIterations = 50,
}) async {
  for (var i = 0; i < maxIterations; i++) {
    if (condition()) return;
    await $.pump(const Duration(milliseconds: 400));
  }
}

/// Taps a [Switch] and waits for its value to flip — retrying the whole
/// tap (not just the wait) up to [attempts] times if it doesn't, rather
/// than a single longer wait. Same idiom as this package's own MFA-
/// secret-read retry (see mfa.dart's `_readMfaSecret`): a dropped tap
/// event and a slow round trip look identical from here (the value just
/// never changes), and retrying the tap covers both — a longer single
/// wait only ever covers the second. Confirmed for real: admin's
/// retention/country/CMEK/audit-logging/FHIR-export toggles all reflect a
/// live Firestore listener, not local optimistic state (the write has to
/// round-trip through a Cloud Function and back down through the
/// listener before the value here changes at all), and a single 16s wait
/// occasionally wasn't enough on a loaded dev machine even though the
/// identical tap+wait had been 100% reliable moments earlier — this is
/// the shared, correct way to drive any of them, not a one-off patch for
/// whichever one happened to fail first.
Future<void> toggleSwitchAndWait(
  PatrolIntegrationTester $,
  Finder switchFinder, {
  int maxIterations = 40,
  int attempts = 3,
}) async {
  final expected = !$.tester.widget<Switch>(switchFinder).value;
  for (var attempt = 0; attempt < attempts; attempt++) {
    await tapFinder($, switchFinder);
    await pumpUntil(
      $,
      () => $.tester.widget<Switch>(switchFinder).value == expected,
      maxIterations: maxIterations,
    );
    if ($.tester.widget<Switch>(switchFinder).value == expected) return;
  }
  expect(
    $.tester.widget<Switch>(switchFinder).value,
    expected,
    reason: 'switch should have flipped to $expected within the retry budget',
  );
}
