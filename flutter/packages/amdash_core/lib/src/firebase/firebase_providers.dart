import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The overridable seams for this package's 4 Firebase SDK singletons.
/// Several providers (`hospitalsProvider`, `ownOrganizationProvider`,
/// `vitalsHistoryProvider`, `userProfileProvider`, and one stream inside
/// `auth_service.dart`) used to call `FirebaseFirestore.instance` directly
/// — and `authServiceProvider`/`mfaServiceProvider`/
/// `patientDecryptionServiceProvider` used to call `FirebaseAuth.instance`/
/// `FirebaseFunctions.instanceFor(...)` directly — even though every
/// class-based service elsewhere already takes its Firebase instance as a
/// constructor param (the established DI pattern in this package). These
/// providers bypassed that entirely, which meant `fake_cloud_firestore`/
/// `firebase_auth_mocks`/mocktail (all real objects you construct and pass
/// around) had no way to substitute in for them: none of them can swap out
/// a singleton getter or static factory call. Routing every provider
/// through these instead makes `ProviderContainer(overrides:
/// [firestoreProvider.overrideWithValue(fakeFirestore)])`-style test setup
/// possible — the real runtime default is unchanged, this is purely a
/// testability seam.
final firestoreProvider = Provider<FirebaseFirestore>((ref) => FirebaseFirestore.instance);

final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

/// Must match `REGION` in `functions/src/shared.ts`, same as the (now
/// redundant, kept only because each file already had its own copy before
/// this seam existed) private `_functionsRegion` constants in
/// `auth_service.dart`/`patient_decryption_service.dart`.
const _functionsRegion = 'northamerica-northeast2';

final firebaseFunctionsProvider =
    Provider<FirebaseFunctions>((ref) => FirebaseFunctions.instanceFor(region: _functionsRegion));

/// `FirebaseAppCheck.instance.activate(...)` itself is a boot-time side
/// effect called once from each app's `main.dart` (before this provider or
/// anything else in the widget tree exists), not something read here — this
/// exists purely so any future widget/service that needs to inspect App
/// Check status (e.g. `getToken`/`onTokenChange`) has the same overridable
/// DI seam as the 3 providers above, instead of reaching for
/// `FirebaseAppCheck.instance` directly.
final firebaseAppCheckProvider = Provider<FirebaseAppCheck>((ref) => FirebaseAppCheck.instance);
