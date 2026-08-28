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
  constructor's own line needs to show as covered.

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
| `amdash_core` | Yes (`very_good_coverage`) | 24% | 24.13% (374/1550 lines) |
| `ems` | Collected, not gated | — | ~0% (placeholder test only) |
| `physician` | Collected, not gated | — | ~0% (placeholder test only) |
| `admin` | Collected, not gated | — | ~0% (placeholder test only) |

Thresholds are a floor, not a target — raise them (and add the missing
`very_good_coverage` step for ems/physician/admin once each has a real
test, so an empty `lcov.info` isn't silently "gated") as the backfill
below lands. Don't lower a threshold to make a change pass; fix the
regression or get real agreement first.

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

**Dart** (Stage A — `amdash_core` services/guards/models — done; app-specific
services and widgets across all 4 packages still at ~0%, see below):
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
- [ ] `amdash_core`/`ems`/`physician`/`admin` widgets (via
      `WidgetTester` + the same provider overrides) — lowest priority;
      the Patrol e2e suite already exercises these end-to-end, so this
      tier is about fast local feedback, not closing a real coverage gap
- [ ] `ems`/`physician`/`admin` app-specific services (`ems_tracking_service.dart`,
      `directions_service.dart`, `patient_upload_service.dart`, etc.)

`amdash_core`'s own package-wide number (24.13%) is lower than "Stage A
done" sounds like it should be because Stage A explicitly excluded that
package's own widgets/screens/theme (the still-unchecked item above) —
every service/guard/model file in Stage A's scope is individually at a
genuine 100%, confirmed by parsing `coverage/lcov.info` directly rather
than trusting the aggregate percentage alone.

## Regulatory note

If AmDash ever goes through Health Canada's medical device pathway (see
the separate device-licensing checklist), ISO 13485/IEC 62304 both
require documented software verification as design-control evidence. A
real, CI-enforced test suite with a visible coverage trail is that
evidence — this file, its roadmap, and the git history of thresholds
ratcheting up are meant to double as that record, not just internal
process.
