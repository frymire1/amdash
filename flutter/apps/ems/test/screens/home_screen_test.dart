import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:ems/classes/uploaded_patient.dart';
import 'package:ems/screens/home_screen.dart';
import 'package:ems/services/ems_alert_service.dart';
import 'package:ems/services/ems_tracking_service.dart';
import 'package:ems/services/patient_session_service.dart';
import 'package:ems/services/patient_upload_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockEmsAlertService extends Mock implements EmsAlertService {}

// Same minimal fake as patient_summary_card_test.dart — HomeScreen embeds a
// PatientSummaryCard per uploaded patient, which reads this directly.
class _FakeEmsTrackingController extends EmsTrackingController {
  _FakeEmsTrackingController(this._initial);
  final Set<String> _initial;

  @override
  Set<String> build() => _initial;

  @override
  Future<void> stopTracking(String patientId) async {}
}

class _MockPatientUploadService extends Mock implements PatientUploadService {}

class _MockFirebaseFunctions extends Mock implements FirebaseFunctions {}

const _patient = Patient(
  id: 'patient-1',
  name: PatientField.resolved('Alex Rivera'),
  gender: 'M',
  age: 34,
  healthcareNumber: PatientField.resolved('HC-123'),
  vitals: PatientVitals(heartRate: 80, bloodPressure: '120/80', oxygen: 98, temperature: 37.0),
);
const _uploaded = UploadedPatient(id: 'patient-1', patient: _patient);

void main() {
  Future<void> pumpScreen(
    WidgetTester tester, {
    AsyncValue<List<UploadedPatient>> patients = const AsyncValue.data([]),
    bool isOffline = false,
  }) {
    return pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        uploadedPatientsProvider.overrideWithValue(patients),
        isOfflineProvider.overrideWithValue(isOffline),
        emsTrackingProvider.overrideWith(() => _FakeEmsTrackingController(const {})),
        emsTrackingHealthProvider.overrideWith((ref) => Stream.value(EmsTrackingHealth.online)),
        ownOrganizationProvider.overrideWith((ref) => Stream.value(null)),
        patientUploadServiceProvider.overrideWithValue(_MockPatientUploadService()),
        fhirExportFunctionsProvider.overrideWithValue(_MockFirebaseFunctions()),
      ],
      routes: {'/home': (_) => const HomeScreen(), '/upload': (_) => const SizedBox(key: Key('upload_route'))},
      initialLocation: '/home',
    );
  }

  testWidgets('loading: shows a spinner', (tester) async {
    await pumpScreen(tester, patients: const AsyncValue.loading());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('no patients uploaded: shows the empty state', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('No patients uploaded yet'), findsOneWidget);
  });

  testWidgets('a load failure shows the inline error', (tester) async {
    await pumpScreen(tester, patients: AsyncValue.error('permission-denied', StackTrace.empty));
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed to load patients:'), findsOneWidget);
  });

  testWidgets('uploaded patients render one keyed PatientSummaryCard each', (tester) async {
    await pumpScreen(tester, patients: const AsyncValue.data([_uploaded]));
    await tester.pumpAndSettle();

    expect(find.text('Alex Rivera'), findsOneWidget);
    expect(find.byKey(const ValueKey('patient-1')), findsOneWidget);
  });

  testWidgets('tapping Add Patient navigates to the upload screen', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Patient'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('upload_route')), findsOneWidget);
  });

  testWidgets('being offline shows the offline banner', (tester) async {
    await pumpScreen(tester, isOffline: true);
    await tester.pumpAndSettle();

    expect(find.textContaining('offline'), findsWidgets);
  });

  group('connectivity-alert registration (initState)', () {
    testWidgets('a signed-in uid registers for connectivity alerts once, on mount', (tester) async {
      final alertService = _MockEmsAlertService();
      when(() => alertService.registerForConnectivityAlerts(any())).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: [
          uploadedPatientsProvider.overrideWithValue(const AsyncValue.data([])),
          isOfflineProvider.overrideWithValue(false),
          emsTrackingProvider.overrideWith(() => _FakeEmsTrackingController(const {})),
          emsTrackingHealthProvider.overrideWith((ref) => Stream.value(EmsTrackingHealth.online)),
          ownOrganizationProvider.overrideWith((ref) => Stream.value(null)),
          patientUploadServiceProvider.overrideWithValue(_MockPatientUploadService()),
          fhirExportFunctionsProvider.overrideWithValue(_MockFirebaseFunctions()),
          authStateProvider.overrideWith((ref) => Stream.value(MockUser(uid: 'ems-uid-1'))),
          emsAlertServiceProvider.overrideWithValue(alertService),
        ],
      );
      addTearDown(container.dispose);
      // Pre-resolve authStateProvider *before* HomeScreen ever mounts —
      // matches real production ordering, where AppRouteGuard/
      // RouterRefreshNotifier already forced this provider to resolve well
      // before HomeScreen becomes reachable at all (see
      // AppRouteGuard.redirect's own ref.read(authStateProvider)). A plain
      // pumpApp (whose ProviderScope creates its own fresh container right
      // as the widget mounts) would leave initState's own ref.read seeing
      // AsyncLoading — a Stream never delivers its first value
      // synchronously (see TESTING.md) — and since initState only runs
      // once, no later pump could retroactively register.
      await container.read(authStateProvider.future);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: HomeScreen())),
        ),
      );
      await tester.pumpAndSettle();

      verify(() => alertService.registerForConnectivityAlerts('ems-uid-1')).called(1);
    });

    testWidgets('no signed-in user (authStateProvider not yet settled): skips registration', (tester) async {
      final alertService = _MockEmsAlertService();

      await pumpApp(
        tester,
        const SizedBox(),
        overrides: [
          uploadedPatientsProvider.overrideWithValue(const AsyncValue.data([])),
          isOfflineProvider.overrideWithValue(false),
          emsTrackingProvider.overrideWith(() => _FakeEmsTrackingController(const {})),
          emsTrackingHealthProvider.overrideWith((ref) => Stream.value(EmsTrackingHealth.online)),
          ownOrganizationProvider.overrideWith((ref) => Stream.value(null)),
          patientUploadServiceProvider.overrideWithValue(_MockPatientUploadService()),
          fhirExportFunctionsProvider.overrideWithValue(_MockFirebaseFunctions()),
          // Never emits — authStateProvider stays AsyncLoading, so
          // valueOrNull is null the whole time, same as home_screen_test.dart's
          // other pumpScreen-based tests (which never override this
          // provider at all).
          authStateProvider.overrideWith((ref) => const Stream<User?>.empty()),
          emsAlertServiceProvider.overrideWithValue(alertService),
        ],
        routes: {'/home': (_) => const HomeScreen()},
        initialLocation: '/home',
      );
      await tester.pumpAndSettle();

      verifyNever(() => alertService.registerForConnectivityAlerts(any()));
    });
  });
}
