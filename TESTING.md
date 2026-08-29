# Testing

Unit test conventions, how to run coverage locally, current thresholds,
and the backfill roadmap toward 100%. This file is also the audit trail
for that backfill — see the design conversation referenced in the
"Regulatory note" section below for why that matters here specifically.

## Scope

`flutter/packages/amdash_core`, `flutter/apps/{ems,physician,admin}`
(Dart), and `functions/` (TypeScript). `marketing/` (the standalone
Angular site) is out of scope — it isn't part of the regulated product
surface.

## "100%" means pragmatic 100%

100% of everything meaningfully unit-testable, with a short, explicit
exclusion list below for platform glue that can't run in a unit-test
sandbox at all — not a silent gap, and not inflated by chasing coverage
on code a unit test genuinely can't exercise.

**Excluded, with why:**
- `lib/main.dart` (each Flutter app) — bootstrapping/wiring; covered by
  the Patrol e2e suite exercising real app startup instead.
- `lib/firebase_options.dart` (each Flutter app) — generated.
- `**/*_web.dart` / `**/*_stub.dart` platform-conditional-export pairs
  (e.g. `reload_page_web.dart`) — the web variant needs a real browser
  (covered by Web e2e); the stub variant is trivial enough to just
  test directly rather than exclude (see
  `amdash_core/test/auth/reload_page_test.dart`) when it's more than a
  true no-op.
- `functions/src/index.ts` — pure re-export wiring; nothing here that
  isn't already guaranteed by `tsc` itself.

Nothing else is excluded. Interface-only files (`functions/src/classes/*.ts`,
which compile to no runtime code at all) aren't excluded either — they
just trivially report 100%, which is correct, not a gap to paper over.

## Running coverage locally

**Flutter** (per package/app):
```
cd flutter/packages/amdash_core   # or apps/{ems,physician,admin}
flutter test --coverage
# coverage/lcov.info written; open with any lcov viewer, or:
```

**Functions**:
```
cd functions
npm test -- --coverage
```
vitest fails the run itself if measured coverage drops below
`functions/vitest.config.ts`'s thresholds — that's the same gate CI
uses, so a local failure here means CI would fail too.

## Mocking conventions

**Dart** (`mocktail` + `fake_cloud_firestore` + `firebase_auth_mocks`,
dev_dependencies in every Flutter package/app — no code-gen step for
any of them, matching this repo's existing no-build_runner convention):
- Every Firebase-touching service class takes its Firestore/Auth/Functions
  instances as constructor parameters (`AuthService(this._auth,
  this._functions, this._firestore)` is the pattern), and the Riverpod
  providers that build them route through this package's own overridable
  seams — `firestoreProvider`/`firebaseAuthProvider`/
  `firebaseFunctionsProvider` in `lib/src/firebase/firebase_providers.dart`
  — instead of calling `FirebaseFirestore.instance` /
  `FirebaseAuth.instance` / `FirebaseFunctions.instanceFor(...)` directly.
  A singleton getter or static factory call can't be swapped out by
  `fake_cloud_firestore`/mocktail at all, so this seam is what makes
  `ProviderContainer(overrides: [firestoreProvider.overrideWithValue(fake)])`
  possible in the first place — tests override these 3 providers (or
  construct a service directly with fakes/mocks) rather than touching the
  real SDK.
- `fake_cloud_firestore`'s `FakeFirebaseFirestore` for anything that
  reads/writes Firestore for real logic (not just a callable wrapper).
- `firebase_auth_mocks`'s `MockFirebaseAuth`/`MockUser` for auth state
  — integrates directly with `FakeFirebaseFirestore` for security-rule-
  aware fakes when that matters. **Confirmed `MockUser` does NOT
  implement `.multiFactor`** (throws `NoSuchMethodError` if touched) —
  for anything MFA-related, use raw mocktail instead (`class _MockUser
  extends Mock implements User {}`, `class _MockMultiFactor extends Mock
  implements MultiFactor {}`, etc.; see `auth/mfa_service_test.dart`).
- `mocktail`'s `Mock`/`when`/`verify` for `FirebaseFunctions`/
  `HttpsCallable` (callables have no fake-implementation package the
  way Firestore/Auth do — mock the interface instead) and any other
  interface-shaped dependency. `class MockFoo extends Mock implements
  Foo {}` works even when `Foo`'s only real constructor is
  private/`@protected` (`HttpsCallable._()`, `FirebaseFunctionsException`,
  `GoRouterState`) — `implements` only needs the public member shape, it
  never calls the constructor.
- Riverpod: `ProviderContainer(overrides: [...])` swapping the
  Firebase-instance providers for fakes, not `ProviderScope` (no widget
  tree needed for a pure provider/service test).
  - **Settling race**: a `Stream`/`Future` never delivers its first value
    synchronously (always at least one microtask later). If the provider
    under test itself `ref.watch`es another async provider, reading
    `.future` on the provider-under-test too early can build once against
    the upstream provider's still-`AsyncLoading` state, then get disposed
    and rebuilt once the upstream settles — surfacing as a wrong-but-fast
    result, or a real `Bad state: ... disposed during loading state`
    error after a full test timeout. Always `await
    container.read(upstreamProvider.future)` before ever reading `.future`
    on the provider under test. To deliberately test an `isLoading`
    branch, override with a stream/future that never emits/completes
    (`StreamController<T>().stream` with nothing added, or an unresolved
    `Completer<T>().future`) — that's checkable synchronously via
    `container.read(provider)`, no timing race possible.
  - A broadcast `StreamController` drops any event pushed via `.add(x)`
    before a listener has subscribed (unlike a single-subscription
    stream, which buffers). To test something that reacts to a value
    pushed *after* construction (e.g. `RouterRefreshNotifier`), force
    early subscription with `container.listen(provider, (_, _) {})`
    before the first `.add(...)` — reading `.future` alone subscribes too
    late, as a side effect.
- `// coverage:ignore-line` marks provably-unreachable platform glue or
  dead defensive code, Dart's equivalent of the `/* v8 ignore next */`
  convention below — **but its placement rule is the opposite of v8's**:
  confirmed by reading `package:coverage`'s own source
  (`lib/src/util.dart`) that the ignored range for the single-line marker
  is exactly the line the comment itself is *on*, so it must be a
  trailing comment on the real code line (`throw StateError('unreachable');
  // coverage:ignore-line`), not a standalone comment line before/after
  it (that just ignores itself, a comment, which was never counted
  anyway). `// coverage:ignore-start` / `-end` don't have this trap —
  they ignore by line-number range regardless of what's on the boundary
  lines, so standalone comment lines work fine for a multi-line block
  (see the two blocks in `auth/mfa_service.dart`). Used in this package
  for: `FileSaver.instance.saveFile(...)` (throws `UnsupportedError` in a
  plain Dart VM test — no fake-implementation package exists the way
  `fake_cloud_firestore` does for Firestore) and
  `TotpMultiFactorGenerator`'s static methods (real platform-channel
  round trips to Firebase's TOTP backend, not mockable — they're static
  SDK calls, not instance methods mocktail can intercept), plus a couple
  of structurally-dead defensive lines (an unreachable-by-construction
  `throw`, a private do-nothing constructor). Verify a "this can't be
  reached" claim empirically (a throwaway probe test) before excluding
  it — don't assume.
- A `const` constructor call is folded at compile time and never
  actually runs, so it does **not** register as a runtime hit on the
  constructor's own declaration line — confirmed via `const
  FhirExportResult(...)` in a test leaving that line at `DA:...,0`
  despite being "constructed." Drop the `const` in the test call if the
  constructor's own line needs to show as covered. **This generalizes to
  every `const` widget constructor, confirmed via a direct A/B across
  Stage C1's own suite**: a widget constructed *only* via `const`
  everywhere in the codebase never shows its constructor line as hit, no
  matter how many real widget tests pump and assert against it; a widget
  with even one non-const call site (often just because a constructor
  arg happens to be a runtime variable, not a literal) does. Not worth
  chasing — don't drop a `const` purely to flip an lcov line; see
  `TESTING.md`'s own coverage-table note for the aggregate-percentage
  impact instead.
- **The widget-test harness** (`test/support/pump_app.dart` in
  `amdash_core`/`ems`/`physician` — each package/app needs its own copy;
  a `test/` directory isn't part of a package's public `lib/`, so it
  can't be imported cross-package even within this monorepo): `pumpApp(tester,
  child, {overrides, brightness, routes, initialLocation})` wraps `child`
  in `ProviderScope(overrides: ...)` + either a plain `MaterialApp(theme:
  ..., home: Scaffold(body: child))` (no `routes` given) or
  `MaterialApp.router(...)` with a real minimal `GoRouter` (only needed
  for widgets calling `context.go`/`.push`/`.pop` — `context.go` resolves
  `GoRouter.of(context)` off the tree, no seam to fake it). `routes`'
  hardcoded `'/'` route renders a keyed sentinel (`pumpAppHomeKey`) so a
  test can assert "navigation reached home" via `find.byKey` — mount the
  widget under test at some *other* path via `initialLocation` when it
  itself needs real routing, not at `'/'`. `Scaffold(body: child)` is
  required even in the no-`routes` branch — a bare `MaterialApp(home:
  child)` has no `Material` ancestor, which throws for anything using an
  `InkWell`/`IconButton`/etc. (confirmed via a real failure testing
  `PatientInfoChip`'s trend-icon button). Provider-override convention:
  override the *specific* provider(s) a widget directly watches/reads via
  `ProviderScope(overrides: [...])`, same as the service-level convention
  above, not by rebuilding a fake Firestore/Auth graph underneath — for a
  `Notifier`-backed provider that a test needs to mutate *after* mounting
  (to trigger a `ref.listen`-driven side effect, which only fires on a
  genuine state *change*, not the initial value), define a small fake
  `Notifier` subclass overriding `build()` to return the seeded initial
  state, with a public method exposing `state = ...` for the test to call
  later (see `_FakeEmsLocationController` in `patient_viewer_test.dart`).
- **`GoogleFonts.config.allowRuntimeFetching = false`** (in each
  package/app's own `test/flutter_test_config.dart`, Flutter's
  auto-discovered suite-wide setup hook) is required before any widget
  test that renders the real theme (`buildLightTheme()`/`buildDarkTheme()`
  call `GoogleFonts.outfit(...)`) — otherwise that's a real network call
  inside `flutter test`. Confirmed via a throwaway probe test that this
  setting alone is sufficient (no bundled font asset needed) —
  `tester.takeException()` stayed `null` pumping the real theme with it
  set.
- **Never `pumpAndSettle()` while anything on screen has a genuinely
  perpetual ticker** — an indeterminate `CircularProgressIndicator`
  (`AnimationController(...)..repeat()` under the hood, same as any
  other "pulsing"/"spinning" widget) never stops scheduling frames on its
  own, so `pumpAndSettle()` loops until its own timeout regardless of
  whether the *visible* state has actually stabilized. This bit multiple
  files this stage (`mfa_security_card.dart`'s reauth flow,
  `nav_bar.dart`'s logout, `mfa_setup_screen.dart`'s resend/check
  spinners, `totp_enrollment_form.dart`'s confirm spinner,
  `work_location_screen.dart`'s save spinner, `patient_viewer.dart`'s
  loading-blur overlay) — the fix is always the same: bounded
  `tester.pump(duration)` calls instead, and if the test specifically
  needs to *observe* the loading state (not just survive it), hold the
  mocked async call open with a `Completer` rather than racing an
  instantly-resolving mock against a single `pump()`.
- **`find.byType(X)` searches the *whole* tree, not just the widget under
  test** — confirmed via a real failure that every `MaterialApp` (even
  wrapping a plain `home:` route) mounts Flutter's own
  `Navigator`/`_ModalScope` machinery, which includes its own
  `AnimatedBuilder` (over a `restorationScopeId` `ValueNotifier`,
  unrelated to whatever the widget under test animates). An unscoped
  `find.byType(AnimatedBuilder)` always finds that ambient one too; scope
  with `find.descendant(of: find.byType(WidgetUnderTest), matching:
  find.byType(AnimatedBuilder))` instead.
- **`mocktail`'s `.thenThrow(x)` makes the mocked method throw
  *synchronously* when called — `.thenAnswer((_) async => throw x)`
  rejects the returned Future *asynchronously* instead, matching what a
  real `async`-bodied method actually does.** These are not
  interchangeable for a method invoked directly (unawaited) from
  `initState()`: a real async method's implementation can never throw
  synchronously (Dart wraps even a throw-before-the-first-`await` into
  the returned Future), so its rejection always surfaces via a
  microtask, safely after the widget's synchronous build/mount phase has
  already unwound. `.thenThrow` skips that — the synchronous throw
  reaches code like `showDialog(...)` while the element is still
  mid-mount, throwing "dependOnInheritedWidgetOfExactType... called
  before initState() completed" (confirmed via a real failure in
  `totp_enrollment_form_test.dart`). Use `.thenThrow` freely for a
  method invoked from a button tap or other post-mount event handler
  (timing-safe either way); use `.thenAnswer((_) async => throw x)` for
  anything reachable from `initState()`.
- **`GoogleMapsFlutterPlatform`** (from `google_maps_flutter_platform_interface`,
  physician's `test/support/mock_google_maps.dart`) follows the same
  `PlatformInterface`/`MockPlatformInterfaceMixin` pattern as
  `GeolocatorPlatform`/`UrlLauncherPlatform` — confirmed via source that
  `GoogleMap` calls `GoogleMapsFlutterPlatform.instance.buildViewWithConfiguration(...)`
  to render itself. `installMockGoogleMaps()` stubs just that call (→ a
  keyed placeholder widget), sufficient for most tests since
  `_mapController?.foo(...)` is null-safe everywhere real code uses it.
  A test that specifically needs a *connected* `GoogleMapController`
  (e.g. to reach `onMapCreated`'s own body, or to verify an
  `animateCamera`/`animateCameraWithConfiguration` call) needs
  `connectGoogleMap(tester, mock)` too — confirmed via a throwaway probe
  that nothing fires `onMapCreated` on its own against a mocked platform
  (unlike a real device, where the native view delivers it
  asynchronously); `connectGoogleMap` captures the platform's own
  `onPlatformViewCreated` callback and invokes it manually, after first
  stubbing all 11 event streams and 9 `update*()`/`animateCamera*()`
  calls `GoogleMapController.init()`/`._connectStreams()` unconditionally
  touch on connect (confirmed via `controller.dart` source — an
  unstubbed `Mock`'s `null` default blows up against each one's
  non-nullable `Stream`/`Future` return type). Note
  `GoogleMapController.animateCamera(...)` itself calls
  `animateCameraWithConfiguration`, not `animateCamera`, on the platform
  instance — confirmed via a real failure stubbing only the latter.
- **`DateTime.now()` cannot be intercepted via `Zone`, at all** —
  confirmed via a throwaway probe test that advancing
  `flutter_test`'s own fake `Timer`/frame clock via `tester.pump(Duration(...))`
  never moves it (unlike `Timer`/`Future.delayed`, which *are*
  Zone-mediated). Any logic gated on real elapsed time — `idle_timeout_wrapper.dart`'s
  15-minute idle check, `patient_viewer.dart`'s glide-animation ticker
  and directions-refresh throttle — is otherwise untestable without
  either waiting out real wall-clock time (never do this) or racing the
  test's own execution speed against real timestamps (flaky). The fix
  used throughout this stage: route the call through `package:clock`'s
  `clock.now()` instead (already a transitive dependency via
  `fake_async`, pinned directly once real `lib/` code imports it
  directly) — the unoverridden `clock` global just calls real
  `DateTime.now()`, so this changes nothing about production behavior —
  then drive it deterministically in tests via `withClock(Clock(() =>
  currentFakeTime), () async { ... })`, mutating `currentFakeTime`
  between `tester.pump(...)` calls as needed. `Clock.fixed(dateTime)` is
  enough for tests that only need one fixed "now"; a mutable closure is
  needed for anything that reads the clock more than once across a
  test's own timeline (e.g. simulating a glide animation's own
  in-progress state).
- **A widget deep in a long `SingleChildScrollView` can sit below the
  default 800×600 test viewport's fold** — `tester.tap(...)`/
  `tester.ensureVisible(...)` both silently compute an offset outside the
  actual render tree in that case (a `warnIfMissed` warning, not a hard
  failure, so it's easy to miss); always `await
  tester.ensureVisible(finder)` immediately before tapping anything that
  might not be the first field on a long form (`patient_upload_screen.dart`'s
  submit button, `mfa_setup_screen.dart`'s Confirm button,
  `patient_viewer.dart`'s Expand-map button all needed this).
- **fl_chart's `LineTouchData` needs a touch landing within
  `touchSpotThreshold` (default `10`) of an actual data point, in the
  chart's own x-axis *data* units — not pixels, and not "anywhere in the
  plot area."** `vitals_trend_dialog.dart` uses elapsed milliseconds as
  its x-axis unit; tapping the chart's visual center missed both test
  data points by ~30 minutes (a threshold of 10ms against an hour-wide
  span). Tap near an actual data point's rendered position instead (e.g.
  the plot area's own left edge for the first entry) — and account for
  `leftTitles`' own `reservedSize` eating into the widget's bounding
  rect before the actual plot area starts. A held gesture
  (`tester.startGesture` + a short `pump` + `.up()`) reached fl_chart's
  touch handling reliably; a bare `tester.tapAt(...)` did not, in this
  version.
- **A widget's field initializer that constructs a real SDK object
  directly (not through a Riverpod provider) has no override seam at
  all** — `PatientViewer`'s own `final DirectionsService _directionsService
  = DirectionsService();` meant *every* `PatientViewer` widget test, not
  just directions-specific ones, would crash on mount (`DirectionsService()`'s
  default constructor eagerly builds a real `FirebaseFunctions.instanceFor(...)`,
  which throws `[core/no-app]` without a live Firebase app — see the
  Firebase-SDK-preconditions note above). Fixed by adding an optional
  constructor parameter (`PatientViewer({..., this.directionsService})`)
  used as `widget.directionsService ?? DirectionsService()` — the real
  call sites never pass it (unchanged production behavior), but a test
  now can. The same pattern `DirectionsService`'s own constructor already
  used for `FirebaseFunctions?`, just one layer up at the widget level.
- **`MockPlatformInterfaceMixin`** (from `plugin_platform_interface`,
  already a transitive dependency of `geolocator`/`flutter_foreground_task`,
  pinned directly in `ems/pubspec.yaml` since test code imports it
  directly) fakes a plugin's platform singleton — e.g. `class
  _MockGeolocatorPlatform extends Mock with MockPlatformInterfaceMixin
  implements GeolocatorPlatform {}`, then `GeolocatorPlatform.instance =
  mock` (restore the real instance in `tearDown`, or it leaks into other
  tests in the same run). Every plugin built on `PlatformInterface`
  guards its `.instance` setter with `PlatformInterface.verify(...)`,
  which normally throws for anything not `extends`-ing the real class —
  `MockPlatformInterfaceMixin` is the plugin author's own sanctioned
  escape hatch for exactly this. Confirmed for real via a throwaway
  probe test that swapping the instance actually intercepts the plugin's
  static calls (`Geolocator.checkPermission()`,
  `FlutterForegroundTask.isRunningService`) rather than a real platform
  channel throwing first — don't assume, confirm.
- Not every plugin static method needs its platform mocked at all —
  some are pure Dart, safe to call for real in a VM test. Confirmed for
  `flutter_foreground_task`'s `init` (sets static fields only),
  `addTaskDataCallback`/`removeTaskDataCallback` (mutate a static
  `List`), and `sendDataToMain` (an `IsolateNameServer.lookupPortByName`
  lookup that returns `null` harmlessly when nothing's registered under
  that name) by reading the plugin's own source, not by guessing.
  `sendDataToMain`'s real effect can even be observed directly: register
  a real `ReceivePort` under the plugin's own port name
  (`'flutter_foreground_task/isolateComPort'`, confirmed via its source)
  with `IsolateNameServer.registerPortWithName(...)`, and the test can
  await what actually arrives on it — no mocking needed for that one at
  all.
- **`SharedPreferences.setMockInitialValues({...})`** (`@visibleForTesting`,
  from `shared_preferences` itself) is the correct, plugin-free way to
  fake `SharedPreferences.getInstance()` — no platform mocking needed.
  Confirmed via its own source that it auto-adds shared_preferences'
  internal `'flutter.'` key prefix if a key doesn't already have it, so
  passing prefixed or unprefixed keys both work.
- **`FlutterForegroundTask`'s own static fields leak across every test
  in the same file** (`isInitialized`, `androidNotificationOptions`,
  etc. — set once by `init()`, never reset automatically) — call the
  plugin's own `FlutterForegroundTask.resetStatic()`
  (`@visibleForTesting`) in `setUp()`. Also set
  `FlutterForegroundTask.skipServiceResponseCheck = true` (also
  `@visibleForTesting`) to skip `startService`/`stopService`'s own extra
  `checkServiceStateChange` polling loop (a real ~5s deadline this
  test suite has no reason to wait out).
- **Merely constructing some Firebase SDK objects throws without a real
  `Firebase.initializeApp()` having run** — confirmed for real that
  `FirebaseFunctions.instanceFor(...)` throws `[core/no-app]` immediately
  at construction, not just when a call is made, in a plain `flutter
  test` run. This means a `Foo([SomeType? dep]) : _dep = dep ??
  RealSingleton.instance` seam's own `??` fallback branch can't be
  exercised by calling the no-arg constructor in a test — mark it `//
  coverage:ignore-line` instead (see `DirectionsService`'s and
  `EmsTrackingTaskHandler`'s constructors), the same "confirmed
  empirically, not assumed" discipline as every other exclusion here.
- **`fake_cloud_firestore`'s `collectionGroup(...)` query is a one-shot
  snapshot** of whatever matched at the moment it was constructed —
  confirmed for real via a throwaway probe test that updating a document
  already included in a live `collectionGroup` query's results never
  re-fires its `.snapshots()` listener at all (ordinary single-collection
  queries don't have this gap). There's no way to exercise "a second
  snapshot arrives" through the fake for a `collectionGroup` query — mock
  `Query`/`QuerySnapshot`/`QueryDocumentSnapshot` directly instead (see
  `ems_location_service_test.dart`'s and
  `patient_upload_service_test.dart`'s own `ignore_for_file:
  subtype_of_sealed_class` groups, and the `@sealed`-vs-`sealed` note
  below for why that's the right call, not a hack).
- **`cloud_firestore` marks `Query`/`DocumentReference`/`DocumentSnapshot`/
  `QuerySnapshot`/`QueryDocumentSnapshot` `@sealed`** — a `package:meta`
  lint annotation (`subtype_of_sealed_class`), *not* the real Dart
  `sealed` keyword (confirmed by reading `cloud_firestore`'s own source:
  they're plain `abstract class`es) — so `Mock implements` still works
  correctly at runtime; only `flutter analyze` complains. When mocking
  one is genuinely the only way to control something `fake_cloud_firestore`
  can't (see the `collectionGroup` note above), suppress the lint with a
  file-level `// ignore_for_file: subtype_of_sealed_class` and a comment
  explaining why, rather than avoiding real, necessary test coverage to
  dodge a lint that doesn't reflect an actual runtime problem.
- **A `Notifier`'s `build()` return value is unconditionally its new
  state** — a `state = x;` assignment made *during* that same synchronous
  `build()` call (e.g. from a `ref.listen(other, callback, fireImmediately:
  true)` registered inside `build()`, calling back into this same
  notifier) gets silently overwritten by whatever `build()` itself later
  `return`s, confirmed via a dedicated probe test (not merely "delayed" —
  genuinely discarded, even after flushing every pending microtask).
  This surfaced as a real, if narrow, bug in `EmsLocationController`: its
  `build()` used `fireImmediately: true` to set initial state via
  `_resubscribe`, which worked by accident for the has-organization case
  (the discarded write just duplicated `build()`'s own default return)
  but silently swallowed the no-organization case's `hasLoadedOnce: true`
  — a signed-in user with no `organizationId`, on a screen that watches
  this provider *after* `userProfileProvider` has already resolved (the
  normal case, since `AppRouteGuard` already waited for it), would get
  stuck reporting "still loading" forever. Fixed by having `build()`
  itself synchronously compute and `return` the correct initial state
  (a new `_rebuild` helper), and dropping `fireImmediately` from the
  `ref.listen` so it only ever fires for genuine *later* changes, safely
  outside `build()`, where a plain `state = ...` assignment behaves
  normally. The general lesson: never rely on a `fireImmediately`
  listener registered inside a `Notifier`'s own `build()` to set that
  same notifier's initial state — compute and return it directly instead.

**TypeScript** (vitest, already the project's choice —
`functions/src/fhir.test.ts` was the first real test file):
- Mock `firebase-admin`/`@google-cloud/kms` at the module level
  (`vi.mock('firebase-admin/firestore', ...)`) rather than the Firebase
  Emulator Suite — that's an integration-test concern, not a unit-test
  one. See `kms.test.ts`/`audit.test.ts` for the pattern.
- **`vi.hoisted()` is required**, not a plain top-level `const`, for any
  variable a `vi.mock()` factory closes over — `vi.mock()` calls are
  hoisted above every other statement in the file (including ordinary
  const declarations textually above them), so referencing an ordinary
  const throws "Cannot access before initialization". Every mock file
  in this repo uses `vi.hoisted()` for exactly this reason.
- A mocked class meant to be used with `new` (e.g.
  `KeyManagementServiceClient`) needs a real `function`-keyword
  implementation assigning onto `this`, not an arrow function returning
  an object literal — arrow functions genuinely cannot be constructors
  in JS, independent of vitest.
- Coverage reporter is `['text', 'lcovonly']`, not `['text', 'lcov']` —
  the plain `lcov` reporter also writes a full per-file HTML report
  tree (dozens of files, including every trivial `classes/*.ts`
  interface), which is neither needed for CI's machine-readable gate
  nor something to generate locally on every test run.
- `/* v8 ignore next */` marks a line as *provably* unreachable (not
  just untested) — used exactly twice in `functions/`, both a
  defensive `x ?? {}`/`: 'active'` fallback that can never actually
  trigger because an earlier check in the same function already
  guaranteed the truthy case (see the comment above each one, in
  `admin.ts`'s `updateUser` and `patient-data.ts`'s
  `exportPatientFhirBundle`). This is the exception, not the pattern —
  reach for a real test first; only mark a line unreachable when you
  can point to the specific earlier check that makes it so.

## `functions/` file organization

Organized by domain, not by which app calls them (an earlier version of
this repo grouped by caller, which produced a confusingly-named
`shared.ts` grab-bag — see git history if curious):
- `auth.ts` — sign-in/account callables (`checkAccountStatus`,
  `setInitialPassword`, `requestPasswordReset`,
  `requestEmailVerification`), plus `getCallerProfile`/`findUserByEmail`,
  which every other domain file reads off of.
- `patient-data.ts` — patient CRUD/triggers, plus the
  `patientLocationRef`/`patientVitalsHistoryCollection` Firestore ref
  builders (`ems.ts`/`physician.ts` import these from here, a real
  cross-domain dependency rather than routing through a generic
  "shared" file).
- `admin.ts`, `ems.ts`, `physician.ts` — still per-app, since those
  genuinely are app-specific (org/user/hospital management; the EMS
  live-location pipeline; the new-patient push alert + Directions
  proxy).
- `kms.ts`/`audit.ts`/`fhir.ts`/`email.ts` — infrastructure/utility
  modules, not Cloud Functions themselves; imported directly by
  whichever domain file needs them.

## Current thresholds (as of this file's last update)

| Package | Gated in CI? | Threshold | Real coverage today |
|---|---|---|---|
| `functions/` | Yes (vitest self-enforces) | 100% per metric | 100%/100%/100%/100% (stmts/branch/funcs/lines) |
| `amdash_core` | Yes (`very_good_coverage`) | 95% | 97.49% (1517/1556 lines) |
| `ems` | Yes (`very_good_coverage`) | 97% | 98.30% (636/647 lines) |
| `physician` | Yes (`very_good_coverage`) | 100% | 100.00% (285/285 lines) |
| `admin` | Yes (`very_good_coverage`) | 12% | 12.42% (142/1143 lines) |

Thresholds are a floor, not a target — raise them as the backfill below
lands. Don't lower a threshold to make a change pass; fix the regression
or get real agreement first.

**Why `admin`'s own number still looks so different from the other
three, even though all four had a comparable amount of real testing
effort put into what's actually in scope so far**: Dart's coverage
collector only instruments files actually reached by the test run's
import graph, not each app's whole `lib/` tree. As of Stage C1,
`amdash_core`'s own widgets/screens/`idle_timeout_wrapper.dart` are
genuinely tested (not just imported-but-untested), and `ems`/`physician`
each gained real widget-level tests for their highest-value screens
(`ems`'s patient-upload flow, `physician`'s map/patient-viewer) — that's
why all three now sit at 95%+. `admin`'s test suite, by contrast, still
doesn't import its own `router.dart` (the one file that would
transitively pull every admin screen/widget in) *except* via
`router_test.dart` (needed to reach `adminRedirect`), which drags in
every untested admin screen/widget as real 0-hit entries — hence
`admin`'s 12.42%, the one number still reflecting a genuine backlog
rather than a coverage-tool artifact. None of this is a gap to paper
over for the other three: every file each stage touched is at a genuine
100% *or* has its remaining gap fully accounted for (confirmed per-file
via `lcov.info`, never by trusting the aggregate alone) — see each
package's own remaining-gap note in the roadmap below.

## Backfill roadmap (highest-value/lowest-effort first)

**`functions/`** — done: 100% on all four metrics, 248 tests, across
every file (`kms.ts`, `audit.ts`, `auth.ts`, `email.ts`,
`patient-data.ts`, `ems.ts`, `physician.ts`, `admin.ts` — 958 lines,
20 callables — and `fhir.ts`). The two lines that aren't literally
executed by a test are marked `/* v8 ignore next */` with a comment
explaining exactly why they're unreachable (see the mocking
conventions section above), not silently excluded from the count.
- [x] `kms.ts`, `audit.ts`, `auth.ts`, `email.ts`, `patient-data.ts`,
      `ems.ts`, `physician.ts`, `admin.ts`, `fhir.ts`

**Dart** (Stage A — `amdash_core` services/guards/models — Stage B —
`ems`/`physician`/`admin` app-specific services — and Stage C1 —
`amdash_core`'s own widgets/screens plus `ems`'s patient-upload flow and
`physician`'s map/patient-viewer — all done; the rest of
`ems`/`physician`/`admin`'s widgets remain, see below):
- [x] `amdash_core`: `isProvidedValue`/`numOrNull`/`bloodPressurePart`,
      `Patient`/`PatientVitals`/`PatientField.fromFirestore`
- [x] `amdash_core` services: `AuthService`, `UserProfileService`,
      `MfaService`, `PatientDecryptionService`, `VitalsHistoryService`,
      `HospitalService`, `OwnOrganizationService`, `FhirExportService`.
      3 of these (`VitalsHistoryService`, `HospitalService`,
      `OwnOrganizationService`) turned out to have no service class at
      all, just a top-level provider reaching `FirebaseFirestore.instance`
      directly and un-overridably — fixed via the new
      `firestoreProvider`/`firebaseAuthProvider`/`firebaseFunctionsProvider`
      DI seam (`lib/src/firebase/firebase_providers.dart`, see the Dart
      mocking-conventions section above) before any of these were
      testable at all, not just untested.
- [x] `amdash_core` Riverpod providers (via `ProviderContainer`
      overrides) — including the `isLoading`-not-`hasValue` stream
      timing guard used throughout this session's own bug fixes, and
      `AppRouteGuard.redirect`'s full auth→MFA→role→work-location chain
      (`guards/app_guards_test.dart`, 21 cases)
- [x] Remaining `amdash_core` model parsers: `Hospital`, `Organization`,
      `AccountStatus`, `VitalsHistoryEntry`, `UserProfile` — the last of
      these caught a real bug (`fcmTokens` used an unsafe cast that threw
      on a non-List value, unlike `role`'s existing safe `is List` check
      one field above it; fixed to match)
- [x] `amdash_core` widgets/screens + `auth/idle_timeout_wrapper.dart`
      (Stage C1 — via `WidgetTester` + a new `test/support/pump_app.dart`
      harness, see the new mocking-convention notes below) — all 18
      files, genuinely 100% except the documented `const`-constructor
      coverage-tool artifact. Found and fixed real bugs along the way:
      `dialogs.dart`'s `showReauthPasswordDialog` disposed its
      `TextEditingController` before the dialog's own exit transition
      finished (refactored to a proper `StatefulWidget` owning it);
      `mfa_security_card.dart`'s reauth-retry path re-showed the "Change
      authenticator app?" confirmation instead of retrying just the
      unenroll step (split into `_unenrollAndProceed`, mirroring
      `TotpEnrollmentForm`'s own `_reauthenticateThenRetry` pattern);
      `totp_enrollment_form.dart`'s "Generate a new code" button cleared
      the old code but never actually re-fetched one; `work_location_screen.dart`
      could get permanently stuck showing a spinner if `_onSubmit` ran
      with no signed-in user.
- [x] `ems`'s patient-upload flow and `physician`'s map/patient-viewer
      (Stage C1, by explicit request — the two highest-value/highest-risk
      screens in the whole widget tier, done ahead of the rest of
      `ems`/`physician`/`admin`'s widgets below): `ems/lib/widgets/location_tracking_section.dart`,
      `ems/lib/screens/patient_upload_screen.dart`,
      `physician/lib/widgets/patient_viewer.dart` — all three at a
      genuine 100%. Required two small, real testability fixes to
      `patient_viewer.dart` itself (both safe, zero production-behavior
      change): `PatientViewer` gained an optional `directionsService`
      constructor param (mirroring `DirectionsService`'s own existing
      `FirebaseFunctions?` seam) — without it, *every* `PatientViewer`
      test would crash on mount, since the field's real
      `DirectionsService()` default throws `[core/no-app]` without a
      live Firebase app; and its glide-animation ticker / directions-
      refresh throttle switched from `DateTime.now()` to `clock.now()`
      (see the new mocking-convention note below) so both are
      deterministically testable instead of racing real wall-clock time.
- [ ] The rest of `ems`/`physician`/`admin`'s widgets (Stage C2+) — lowest
      remaining priority; the Patrol e2e suite already exercises these
      end-to-end, so this tier is about fast local feedback, not closing
      a real coverage gap
- [x] `ems`/`physician`/`admin` app-specific services (Stage B) —
      `ems`: `PatientUploadService`, `patient_session_service.dart`'s
      `uploadedPatientsProvider`, `EmsTrackingController`,
      `EmsTrackingTaskHandler` (the Android foreground-service isolate
      entry point), `UploadedPatient`. `physician`:
      `DirectionsService`/`DirectionsCacheController`,
      `EmsLocationController`, `PatientAlertService`, `patient_service.dart`'s
      `physicianPatientsProvider`, `ActiveLocation`, `distanceMeters`.
      `admin`: `AdminService`, `organization_service.dart`'s
      `organizationsProvider`, `AuditLogEntry`/`AuditLogPage`/`ManagedUser`
      parsers, `organizationCountries`, and `router.dart`'s custom
      `adminRedirect` guard chain (admin doesn't reuse `AppRouteGuard` —
      see that function's own doc comment). Every file above is at a
      genuine 100% (confirmed per-file via `lcov.info`); a couple of
      platform-glue/SDK-precondition lines are excluded with the same
      documented-not-silent `// coverage:ignore` discipline as Stage A
      (see the new Dart mocking-convention notes below for what and why).
      `ems`/`physician`'s own `router.dart` were **not** given dedicated
      test files — both are thin `GoRouter` wiring whose entire
      `redirect` behavior already lives in, and is already tested via,
      `AppRouteGuard.redirect` (Stage A); a dedicated test would just
      re-test that guard through an extra layer of indirection.

`amdash_core`'s remaining ~2.5% gap (39 lines) is *not* a backlog — every
one of them is the same well-known Dart/Flutter coverage-tool artifact:
a `const` widget constructor invoked *only* via `const` call sites
(everywhere in both `lib/` and every test file) gets folded away at
compile time and never registers a runtime hit on its own declaration
line, even though real widget tests genuinely construct and render that
widget. Confirmed by direct A/B comparison within this same package:
`GlassPanel`/`StatusPill` (which happen to also get constructed non-const
somewhere) show their constructor line as covered; `AppBackground`/
`PatientVitalsChips`/`IdleTimeoutWrapper`/etc. (constructed *only* via
`const` everywhere) don't — despite every one of those widgets being
pumped and asserted against by real tests. Don't chase this by
deliberately dropping a `const` somewhere just to flip an lcov line; that
would be optimizing the metric, not the actual test. `ems`'s remaining
~1.7% gap is entirely `lib/firebase_options.dart` (generated, out of
scope — see the exclusion list above; it just isn't gated the same way
`min_coverage` is per-package rather than per-file). `admin`'s own
number is the one genuine backlog left — see the coverage-table note
above for why.

## Regulatory note

If AmDash ever goes through Health Canada's medical device pathway (see
the separate device-licensing checklist), ISO 13485/IEC 62304 both
require documented software verification as design-control evidence. A
real, CI-enforced test suite with a visible coverage trail is that
evidence — this file, its roadmap, and the git history of thresholds
ratcheting up are meant to double as that record, not just internal
process.
