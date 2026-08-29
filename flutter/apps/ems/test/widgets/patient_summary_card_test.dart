import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:ems/classes/uploaded_patient.dart';
import 'package:ems/services/ems_tracking_service.dart';
import 'package:ems/services/patient_upload_service.dart';
import 'package:ems/widgets/patient_summary_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

// A minimal fake for emsTrackingProvider, same rationale as
// location_tracking_section_test.dart's — this card only ever reads the
// tracked-id set and calls stopTracking(), so there's no need to replicate
// EmsTrackingController's real Firebase/foreground-task machinery here.
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

class _MockHttpsCallable extends Mock implements HttpsCallable {}

class _MockHttpsCallableResult<T> extends Mock implements HttpsCallableResult<T> {}

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
  late _MockPatientUploadService uploadService;
  late _MockFirebaseFunctions functions;
  late _MockHttpsCallable exportCallable;

  setUp(() {
    uploadService = _MockPatientUploadService();
    functions = _MockFirebaseFunctions();
    exportCallable = _MockHttpsCallable();
    when(() => functions.httpsCallable('exportPatientFhirBundle')).thenReturn(exportCallable);
  });

  Future<void> pumpCard(
    WidgetTester tester, {
    Set<String> trackedIds = const {},
    EmsTrackingHealth health = EmsTrackingHealth.online,
    Organization? organization,
  }) {
    return pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        emsTrackingProvider.overrideWith(() => _FakeEmsTrackingController(trackedIds)),
        emsTrackingHealthProvider.overrideWith((ref) => Stream.value(health)),
        ownOrganizationProvider.overrideWith((ref) => Stream.value(organization)),
        patientUploadServiceProvider.overrideWithValue(uploadService),
        fhirExportFunctionsProvider.overrideWithValue(functions),
      ],
      routes: {
        '/card': (_) => const PatientSummaryCard(uploaded: _uploaded),
        '/patient/patient-1': (_) => const SizedBox(key: Key('patient_viewer_route')),
        '/upload/patient-1': (_) => const SizedBox(key: Key('upload_route')),
      },
      initialLocation: '/card',
    );
  }

  group('tracking pill', () {
    testWidgets('not tracking: shows the offline pill (never pulses)', (tester) async {
      await pumpCard(tester, trackedIds: const {});
      await tester.pumpAndSettle();

      expect(find.text('TRACKING OFFLINE'), findsOneWidget);
    });

    testWidgets('tracking + healthy: shows the pulsing "Tracking Online" pill', (tester) async {
      await pumpCard(tester, trackedIds: const {'patient-1'}, health: EmsTrackingHealth.online);
      // Never pumpAndSettle() here — pulsing:true means a perpetual ticker.
      await tester.pump();
      await tester.pump();

      expect(find.text('TRACKING ONLINE'), findsOneWidget);
    });

    testWidgets('tracking + location services off: shows the matching warning pill', (tester) async {
      await pumpCard(tester, trackedIds: const {'patient-1'}, health: EmsTrackingHealth.locationOff);
      await tester.pumpAndSettle();

      expect(find.text('LOCATION OFF'), findsOneWidget);
    });

    testWidgets('tracking + permission denied: shows the matching warning pill', (tester) async {
      await pumpCard(tester, trackedIds: const {'patient-1'}, health: EmsTrackingHealth.permissionDenied);
      await tester.pumpAndSettle();

      expect(find.text('LOCATION PERMISSION OFF'), findsOneWidget);
    });

    testWidgets('tracking + stale fix: shows the "No GPS Signal" pill', (tester) async {
      await pumpCard(tester, trackedIds: const {'patient-1'}, health: EmsTrackingHealth.noSignal);
      await tester.pumpAndSettle();

      expect(find.text('NO GPS SIGNAL'), findsOneWidget);
    });
  });

  group('navigation', () {
    testWidgets('tapping the card body opens the read-only patient viewer', (tester) async {
      await pumpCard(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Alex Rivera'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('patient_viewer_route')), findsOneWidget);
    });

    testWidgets('tapping Edit opens the upload/edit screen', (tester) async {
      await pumpCard(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('upload_route')), findsOneWidget);
    });
  });

  group('delete', () {
    testWidgets('canceling the confirm dialog never calls deletePatient', (tester) async {
      await pumpCard(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(() => uploadService.deletePatient(any()));
    });

    testWidgets('confirming deletes the patient', (tester) async {
      when(() => uploadService.deletePatient(any())).thenAnswer((_) async {});

      await pumpCard(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();

      verify(() => uploadService.deletePatient('patient-1')).called(1);
    });

    testWidgets('a failed delete shows the inline error', (tester) async {
      when(() => uploadService.deletePatient(any())).thenThrow(Exception('permission-denied'));

      await pumpCard(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();

      expect(find.text('Failed to delete patient. Please try again.'), findsOneWidget);
    });
  });

  group('complete transport', () {
    testWidgets('org without FHIR export enabled: dialog omits the export disclosure', (tester) async {
      await pumpCard(tester, organization: const Organization(id: 'org-1', name: 'Org', fhirExportEnabled: false));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Complete Transport'));
      await tester.pumpAndSettle();

      expect(find.textContaining('exported as FHIR automatically'), findsNothing);
      expect(find.textContaining('Live tracking will stop'), findsOneWidget);
    });

    testWidgets('org with FHIR export enabled: dialog discloses the automatic export', (tester) async {
      await pumpCard(tester, organization: const Organization(id: 'org-1', name: 'Org', fhirExportEnabled: true));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Complete Transport'));
      await tester.pumpAndSettle();

      expect(find.textContaining('exported as FHIR automatically'), findsOneWidget);
    });

    testWidgets('canceling the confirm dialog never calls completeTransportConfirmed', (tester) async {
      await pumpCard(tester, organization: const Organization(id: 'org-1', name: 'Org'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Complete Transport'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(() => uploadService.completeTransportConfirmed(any()));
    });

    testWidgets('confirming without FHIR export enabled completes transport and never exports', (tester) async {
      when(() => uploadService.completeTransportConfirmed(any())).thenAnswer((_) async {});

      await pumpCard(tester, organization: const Organization(id: 'org-1', name: 'Org', fhirExportEnabled: false));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Complete Transport'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Complete Transport').last);
      await tester.pumpAndSettle();

      verify(() => uploadService.completeTransportConfirmed('patient-1')).called(1);
      verifyNever(() => exportCallable.call<Map<Object?, Object?>>(any()));
    });

    testWidgets('a failed complete shows the inline error and never attempts export', (tester) async {
      when(() => uploadService.completeTransportConfirmed(any())).thenThrow(StateError('never confirmed'));

      await pumpCard(tester, organization: const Organization(id: 'org-1', name: 'Org', fhirExportEnabled: true));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Complete Transport'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Complete Transport').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('complete_transport_error')), findsOneWidget);
      verifyNever(() => exportCallable.call<Map<Object?, Object?>>(any()));
    });

    testWidgets(
      'confirming with FHIR export enabled chains into an export attempt, which fails at the '
      'unmockable-in-tests FileSaver boundary and shows the generic export error',
      (tester) async {
        when(() => uploadService.completeTransportConfirmed(any())).thenAnswer((_) async {});
        when(() => exportCallable.call<Map<Object?, Object?>>(any())).thenThrow(
          FirebaseFunctionsException(code: 'internal', message: 'boom'),
        );

        await pumpCard(tester, organization: const Organization(id: 'org-1', name: 'Org', fhirExportEnabled: true));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Complete Transport'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Complete Transport').last);
        await tester.pumpAndSettle();

        verify(() => uploadService.completeTransportConfirmed('patient-1')).called(1);
        expect(find.byKey(const Key('fhir_export_error')), findsOneWidget);
        expect(find.text('boom'), findsOneWidget);
      },
    );

    testWidgets(
      // exportPatientFhirBundle's own success path always ends by calling
      // FileSaver.instance.saveFile, which throws UnsupportedError in a
      // plain `flutter test` run (see fhir_export_service.dart's own
      // coverage:ignore block) — so a *successful* callable response still
      // can't reach _autoExportFhir's success-message branch here, only its
      // generic catch. This test is the empirical confirmation for that
      // (not an assumption): the widget's own success-message setState is
      // therefore coverage:ignore'd, cross-referencing this same boundary.
      'confirming with a successful callable response still lands in the generic export error '
      '(FileSaver is unmockable in a plain VM test)',
      (tester) async {
        final response = _MockHttpsCallableResult<Map<Object?, Object?>>();
        when(() => response.data).thenReturn({
          'bundle': {'resourceType': 'Bundle', 'entry': <Object?>[]},
        });
        when(() => uploadService.completeTransportConfirmed(any())).thenAnswer((_) async {});
        when(() => exportCallable.call<Map<Object?, Object?>>(any())).thenAnswer((_) async => response);

        await pumpCard(tester, organization: const Organization(id: 'org-1', name: 'Org', fhirExportEnabled: true));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Complete Transport'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Complete Transport').last);
        await tester.pumpAndSettle();

        verify(() => uploadService.completeTransportConfirmed('patient-1')).called(1);
        expect(find.byKey(const Key('fhir_export_error')), findsOneWidget);
        expect(find.text("Couldn't export this patient's FHIR record. Please try again."), findsOneWidget);
      },
    );
  });
}
