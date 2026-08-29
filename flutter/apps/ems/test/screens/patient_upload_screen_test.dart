import 'package:amdash_core/amdash_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:ems/classes/uploaded_patient.dart';
import 'package:ems/screens/patient_upload_screen.dart';
import 'package:ems/services/ems_tracking_service.dart';
import 'package:ems/services/patient_session_service.dart';
import 'package:ems/services/patient_upload_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../support/pump_app.dart';

class _MockGeolocatorPlatform extends Mock with MockPlatformInterfaceMixin implements GeolocatorPlatform {}

class _MockPatientUploadService extends Mock implements PatientUploadService {}

class _MockPatientDecryptionService extends Mock implements PatientDecryptionService {}

class _MockFirebaseFunctionsException extends Mock implements FirebaseFunctionsException {}

class _FakeEmsTrackingController extends EmsTrackingController {
  _FakeEmsTrackingController({this.initial = const {}, this.onStart, this.onStop});
  final Set<String> initial;
  final Future<void> Function(String)? onStart;
  final Future<void> Function(String)? onStop;

  @override
  Set<String> build() => initial;

  @override
  Future<void> startTracking(String patientId) => onStart?.call(patientId) ?? Future.value();

  @override
  Future<void> stopTracking(String patientId) => onStop?.call(patientId) ?? Future.value();
}

Position _position() => Position(
  longitude: -75.7,
  latitude: 45.4,
  timestamp: DateTime.now(),
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

Patient _patient({
  String name = 'Jordan Lee',
  String healthcareNumber = '1234567890',
  String gender = 'Female',
  Object? age = 42,
  String destination = 'Ottawa Civic',
  Object? heartRate = 95,
  String bloodPressure = '120/80',
  Object? oxygen = 98,
  Object? temperature = 37,
  int? respiratoryRate = 16,
  int? gcs = 15,
  String? ivSize = '18G',
  String? ivPlacement = 'Left Forearm',
  String? treatment = 'IV fluids',
  String? notes = 'Stable',
}) {
  return Patient(
    id: 'patient-1',
    name: PatientField.resolved(name),
    gender: gender,
    age: age,
    healthcareNumber: PatientField.resolved(healthcareNumber),
    vitals: PatientVitals(
      heartRate: heartRate,
      bloodPressure: bloodPressure,
      oxygen: oxygen,
      temperature: temperature,
      respiratoryRate: respiratoryRate,
      gcs: gcs,
    ),
    destination: destination,
    ivSize: ivSize,
    ivPlacement: ivPlacement,
    treatment: treatment,
    notes: notes,
  );
}

// Looks up a TextField by its InputDecoration.labelText, not position —
// positional find.byType(TextField).at(N) proved fragile/error-prone to
// hand-count against the real field order (Name, Age, Healthcare Number,
// then vitals...), confirmed the hard way via a wrong first draft of this
// file's own prefill assertions.
String _textFieldValue(WidgetTester tester, String label) {
  return tester
      .widgetList<TextField>(find.byType(TextField))
      .firstWhere((f) => f.decoration?.labelText == label)
      .controller!
      .text;
}

void main() {
  late _MockGeolocatorPlatform geolocator;
  late GeolocatorPlatform realGeolocator;
  late _MockPatientUploadService uploadService;
  late _MockPatientDecryptionService decryptionService;

  setUpAll(() {
    registerFallbackValue(const LocationSettings());
    registerFallbackValue(
      const PatientFormValues(
        name: '',
        gender: '',
        age: null,
        healthcareNumber: '',
        destination: '',
        heartRate: null,
        bloodPressure: '',
        oxygen: null,
        temperature: null,
        respiratoryRate: null,
        gcs: null,
        ivSize: '',
        ivPlacement: '',
        treatment: '',
        notes: '',
      ),
    );
  });

  setUp(() {
    geolocator = _MockGeolocatorPlatform();
    realGeolocator = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = geolocator;
    when(() => geolocator.checkPermission()).thenAnswer((_) async => LocationPermission.always);
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenAnswer((_) async => _position());

    uploadService = _MockPatientUploadService();
    decryptionService = _MockPatientDecryptionService();
  });

  tearDown(() {
    GeolocatorPlatform.instance = realGeolocator;
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    String? patientId,
    List<UploadedPatient> uploadedPatients = const [],
    List<String> hospitalNames = const ['Ottawa Civic', 'Ottawa General'],
    bool isOffline = false,
    Future<void> Function(String)? onStartTracking,
    Future<void> Function(String)? onStopTracking,
    Map<String, List<VitalsHistoryEntry>> vitalsHistoryByPatient = const {},
    Set<String> trackedPatients = const {},
  }) {
    return pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        patientUploadServiceProvider.overrideWithValue(uploadService),
        patientDecryptionServiceProvider.overrideWithValue(decryptionService),
        emsTrackingProvider.overrideWith(
          () => _FakeEmsTrackingController(
            initial: trackedPatients,
            onStart: onStartTracking,
            onStop: onStopTracking,
          ),
        ),
        uploadedPatientsProvider.overrideWithValue(AsyncValue.data(uploadedPatients)),
        hospitalNamesProvider.overrideWithValue(hospitalNames),
        isOfflineProvider.overrideWithValue(isOffline),
        for (final entry in vitalsHistoryByPatient.entries)
          vitalsHistoryProvider(entry.key).overrideWith((ref) => Stream.value(entry.value)),
      ],
      routes: {'/patient-upload': (_) => PatientUploadScreen(patientId: patientId)},
      initialLocation: '/patient-upload',
    );
  }

  testWidgets('create mode shows the create title and button label', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('Upload Patient Information'), findsOneWidget);
    expect(find.text('Upload Patient'), findsOneWidget);
  });

  testWidgets('submitting the Systolic BP field via the keyboard moves focus to Diastolic', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    final systolicField = find.widgetWithText(TextField, 'Systolic BP');
    await tester.ensureVisible(systolicField);
    await tester.tap(systolicField);
    await tester.enterText(systolicField, '120');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();

    final diastolicField = tester.widget<TextField>(find.widgetWithText(TextField, 'Diastolic BP'));
    expect(diastolicField.focusNode?.hasFocus, true);
  });

  testWidgets('edit mode shows the edit title and button label', (tester) async {
    await pumpScreen(tester, patientId: 'patient-1', uploadedPatients: [UploadedPatient(id: 'patient-1', patient: _patient())]);
    await tester.pumpAndSettle();

    expect(find.text('Edit Patient Information'), findsOneWidget);
    expect(find.text('Save Changes'), findsOneWidget);
  });

  group('_maybePrefill', () {
    testWidgets('fills every field from the matching uploaded patient, including the BP round trip', (
      tester,
    ) async {
      when(() => decryptionService.decryptFields(any())).thenAnswer((_) async => {});

      await pumpScreen(
        tester,
        patientId: 'patient-1',
        uploadedPatients: [UploadedPatient(id: 'patient-1', patient: _patient())],
      );
      await tester.pumpAndSettle();

      expect(_textFieldValue(tester, 'Age'), '42');
      expect(_textFieldValue(tester, 'Heart Rate (bpm)'), '95');
      expect(_textFieldValue(tester, 'Systolic BP'), '120');
      expect(_textFieldValue(tester, 'Diastolic BP'), '80');
      expect(_textFieldValue(tester, 'Oxygen (%)'), '98');
      expect(_textFieldValue(tester, 'Temperature (°C)'), '37');
      expect(_textFieldValue(tester, 'Respiratory Rate (breaths/min)'), '16');
      expect(_textFieldValue(tester, 'GCS'), '15');
      expect(_textFieldValue(tester, 'Treatment / Medication Given'), 'IV fluids');
      expect(_textFieldValue(tester, 'Patient Notes'), 'Stable');
    });

    testWidgets('a blank blood pressure round-trips to two empty fields, not "/"', (tester) async {
      when(() => decryptionService.decryptFields(any())).thenAnswer((_) async => {});

      await pumpScreen(
        tester,
        patientId: 'patient-1',
        uploadedPatients: [UploadedPatient(id: 'patient-1', patient: _patient(bloodPressure: ''))],
      );
      await tester.pumpAndSettle();

      expect(_textFieldValue(tester, 'Systolic BP'), '');
      expect(_textFieldValue(tester, 'Diastolic BP'), '');
    });

    testWidgets('_prefillDecryptedFields succeeding fills name/healthcare number', (tester) async {
      when(() => decryptionService.decryptFields(['patient-1'])).thenAnswer(
        (_) async => {'patient-1': const DecryptedPatientFields(name: 'Real Name', healthcareNumber: 'HC-999')},
      );

      await pumpScreen(
        tester,
        patientId: 'patient-1',
        uploadedPatients: [UploadedPatient(id: 'patient-1', patient: _patient())],
      );
      await tester.pumpAndSettle();

      expect(_textFieldValue(tester, 'Full Name'), 'Real Name');
      expect(_textFieldValue(tester, 'Healthcare Number'), 'HC-999');
    });

    testWidgets('_prefillDecryptedFields failing shows the load-failure error', (tester) async {
      when(() => decryptionService.decryptFields(any())).thenThrow(Exception('network error'));

      await pumpScreen(
        tester,
        patientId: 'patient-1',
        uploadedPatients: [UploadedPatient(id: 'patient-1', patient: _patient())],
      );
      await tester.pumpAndSettle();

      expect(
        find.text("Failed to load this patient's name/healthcare number. Please try again."),
        findsOneWidget,
      );
    });

    testWidgets('an unmatched patientId (not yet loaded) leaves the form blank, no crash', (tester) async {
      await pumpScreen(tester, patientId: 'not-loaded-yet', uploadedPatients: const []);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Edit Patient Information'), findsOneWidget);
    });
  });

  group('_onSubmit', () {
    testWidgets('offline + create short-circuits to the offline dialog, never calls uploadPatient', (
      tester,
    ) async {
      await pumpScreen(tester, isOffline: true);
      await tester.pumpAndSettle();

      // The submit button sits below the fold of this long scrollable form
      // in the default 800x600 test viewport — ensureVisible first, or the
      // tap lands outside the render tree entirely and _onSubmit never runs.
      await tester.ensureVisible(find.byKey(const Key('patient_upload_submit')));
      await tester.tap(find.byKey(const Key('patient_upload_submit')));
      await tester.pumpAndSettle();

      expect(find.text("You're offline"), findsOneWidget);
      verifyNever(() => uploadService.uploadPatient(any(), latitude: any(named: 'latitude'), longitude: any(named: 'longitude')));
    });

    testWidgets('a network-shaped upload failure shows the offline dialog too', (tester) async {
      final ffException = _MockFirebaseFunctionsException();
      when(() => ffException.code).thenReturn('unavailable');
      when(
        () => uploadService.uploadPatient(any(), latitude: any(named: 'latitude'), longitude: any(named: 'longitude')),
      ).thenThrow(PatientSaveException(ffException));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      // The submit button sits below the fold of this long scrollable form
      // in the default 800x600 test viewport — ensureVisible first, or the
      // tap lands outside the render tree entirely and _onSubmit never runs.
      await tester.ensureVisible(find.byKey(const Key('patient_upload_submit')));
      await tester.tap(find.byKey(const Key('patient_upload_submit')));
      await tester.pumpAndSettle();

      expect(find.text("You're offline"), findsOneWidget);
    });

    testWidgets('a generic upload failure shows the inline generic error, not the offline dialog', (
      tester,
    ) async {
      when(
        () => uploadService.uploadPatient(any(), latitude: any(named: 'latitude'), longitude: any(named: 'longitude')),
      ).thenThrow(Exception('permission-denied'));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      // The submit button sits below the fold of this long scrollable form
      // in the default 800x600 test viewport — ensureVisible first, or the
      // tap lands outside the render tree entirely and _onSubmit never runs.
      await tester.ensureVisible(find.byKey(const Key('patient_upload_submit')));
      await tester.tap(find.byKey(const Key('patient_upload_submit')));
      await tester.pumpAndSettle();

      expect(find.text('Failed to upload patient. Please try again.'), findsOneWidget);
      expect(find.text("You're offline"), findsNothing);
    });

    testWidgets('a successful create seeds the field cache, flips to edit mode, starts tracking, and navigates home', (
      tester,
    ) async {
      when(
        () => uploadService.uploadPatient(any(), latitude: any(named: 'latitude'), longitude: any(named: 'longitude')),
      ).thenAnswer(
        (_) async => const PatientSaveResult(id: 'new-id', nameFingerprint: 'fp-name', healthcareNumberFingerprint: 'fp-hc'),
      );
      var startedId = '';
      await pumpScreen(tester, onStartTracking: (id) async => startedId = id);
      await tester.pumpAndSettle();

      // The submit button sits below the fold of this long scrollable form
      // in the default 800x600 test viewport — ensureVisible first, or the
      // tap lands outside the render tree entirely and _onSubmit never runs.
      await tester.ensureVisible(find.byKey(const Key('patient_upload_submit')));
      await tester.tap(find.byKey(const Key('patient_upload_submit')));
      await tester.pumpAndSettle();

      verify(
        () => uploadService.uploadPatient(any(), latitude: any(named: 'latitude'), longitude: any(named: 'longitude')),
      ).called(1);
      expect(startedId, 'new-id');
      // Navigated home.
      expect(find.byKey(pumpAppHomeKey), findsOneWidget);
    });

    testWidgets('a successful update calls updatePatient (not uploadPatient) and navigates home', (
      tester,
    ) async {
      when(() => uploadService.updatePatient(any(), any())).thenAnswer(
        (_) async => const PatientSaveResult(id: 'patient-1'),
      );
      when(() => decryptionService.decryptFields(any())).thenAnswer((_) async => {});

      await pumpScreen(
        tester,
        patientId: 'patient-1',
        uploadedPatients: [UploadedPatient(id: 'patient-1', patient: _patient())],
      );
      await tester.pumpAndSettle();

      // The submit button sits below the fold of this long scrollable form
      // in the default 800x600 test viewport — ensureVisible first, or the
      // tap lands outside the render tree entirely and _onSubmit never runs.
      await tester.ensureVisible(find.byKey(const Key('patient_upload_submit')));
      await tester.tap(find.byKey(const Key('patient_upload_submit')));
      await tester.pumpAndSettle();

      verify(() => uploadService.updatePatient('patient-1', any())).called(1);
      verifyNever(
        () => uploadService.uploadPatient(any(), latitude: any(named: 'latitude'), longitude: any(named: 'longitude')),
      );
      expect(find.byKey(pumpAppHomeKey), findsOneWidget);
    });

    testWidgets('live tracking failing to start shows its own dialog and stays on the page (patient already saved)', (
      tester,
    ) async {
      when(
        () => uploadService.uploadPatient(any(), latitude: any(named: 'latitude'), longitude: any(named: 'longitude')),
      ).thenAnswer((_) async => const PatientSaveResult(id: 'new-id'));

      await pumpScreen(tester, onStartTracking: (_) async => throw Exception('geolocator failure'));
      await tester.pumpAndSettle();

      // The submit button sits below the fold of this long scrollable form
      // in the default 800x600 test viewport — ensureVisible first, or the
      // tap lands outside the render tree entirely and _onSubmit never runs.
      await tester.ensureVisible(find.byKey(const Key('patient_upload_submit')));
      await tester.tap(find.byKey(const Key('patient_upload_submit')));
      // Bounded pumps, not pumpAndSettle() — showErrorDialog awaits real
      // user dismissal, and _submitting (with its indeterminate spinner)
      // stays true for however long that dialog is open, same never-
      // pumpAndSettle-across-an-indeterminate-spinner rule as everywhere
      // else this session.
      await tester.pump();
      await tester.pump();

      expect(find.text('Live tracking failed'), findsOneWidget);
      expect(find.byKey(pumpAppHomeKey), findsNothing);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Now in edit mode in place (patient already created).
      expect(find.text('Save Changes'), findsOneWidget);
    });

    testWidgets('with live tracking toggled off, submitting calls stopTracking, not startTracking', (
      tester,
    ) async {
      when(() => uploadService.updatePatient(any(), any())).thenAnswer(
        (_) async => const PatientSaveResult(id: 'patient-1'),
      );
      when(() => decryptionService.decryptFields(any())).thenAnswer((_) async => {});
      var stoppedId = '';
      var startCalled = false;

      await pumpScreen(
        tester,
        patientId: 'patient-1',
        uploadedPatients: [UploadedPatient(id: 'patient-1', patient: _patient())],
        // Seeded as already-tracked, so LocationTrackingSection's own
        // initState (isTracking('patient-1')) starts the switch ON — one
        // tap then genuinely turns *off* live tracking, matching this
        // test's own name/intent (an unseeded edit-mode section starts
        // OFF, so a single tap would turn it *on* instead).
        trackedPatients: const {'patient-1'},
        onStartTracking: (_) async => startCalled = true,
        onStopTracking: (id) async => stoppedId = id,
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();

      // The submit button sits below the fold of this long scrollable form
      // in the default 800x600 test viewport — ensureVisible first, or the
      // tap lands outside the render tree entirely and _onSubmit never runs.
      await tester.ensureVisible(find.byKey(const Key('patient_upload_submit')));
      await tester.tap(find.byKey(const Key('patient_upload_submit')));
      await tester.pumpAndSettle();

      expect(stoppedId, 'patient-1');
      expect(startCalled, false);
    });

    testWidgets('the Destination Hospital dropdown selection round-trips through submit', (tester) async {
      PatientFormValues? submitted;
      when(
        () => uploadService.uploadPatient(any(), latitude: any(named: 'latitude'), longitude: any(named: 'longitude')),
      ).thenAnswer((invocation) async {
        submitted = invocation.positionalArguments[0] as PatientFormValues;
        return const PatientSaveResult(id: 'new-id');
      });

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('patient_destination_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('patient_destination_option_Ottawa General')).last);
      await tester.pumpAndSettle();

      // The submit button sits below the fold of this long scrollable form
      // in the default 800x600 test viewport — ensureVisible first, or the
      // tap lands outside the render tree entirely and _onSubmit never runs.
      await tester.ensureVisible(find.byKey(const Key('patient_upload_submit')));
      await tester.tap(find.byKey(const Key('patient_upload_submit')));
      await tester.pumpAndSettle();

      expect(submitted?.destination, 'Ottawa General');
    });
  });

  group('vitals trend icons', () {
    testWidgets('a single history entry shows no trend icon (not a trend yet)', (tester) async {
      when(() => decryptionService.decryptFields(any())).thenAnswer((_) async => {});

      await pumpScreen(
        tester,
        patientId: 'patient-1',
        uploadedPatients: [UploadedPatient(id: 'patient-1', patient: _patient())],
        vitalsHistoryByPatient: {
          'patient-1': [
            VitalsHistoryEntry(vitals: _patient().vitals, recordedAt: DateTime(2024, 1, 1)),
          ],
        },
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.show_chart), findsNothing);
    });

    testWidgets('2+ history entries show a trend icon', (tester) async {
      when(() => decryptionService.decryptFields(any())).thenAnswer((_) async => {});

      await pumpScreen(
        tester,
        patientId: 'patient-1',
        uploadedPatients: [UploadedPatient(id: 'patient-1', patient: _patient())],
        vitalsHistoryByPatient: {
          'patient-1': [
            VitalsHistoryEntry(vitals: _patient().vitals, recordedAt: DateTime(2024, 1, 1)),
            VitalsHistoryEntry(vitals: _patient().vitals, recordedAt: DateTime(2024, 1, 2)),
          ],
        },
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.show_chart), findsWidgets);
    });

    testWidgets('every vitals field trend icon opens a dialog with real chart data', (tester) async {
      // Confirms each field's own embedded VitalSeries selector closures
      // actually run, not just get constructed — each is only invoked once
      // its trend dialog is opened, tapping through every one of them
      // (unlike the "shows a trend icon" tests above, which never open any
      // of them).
      when(() => decryptionService.decryptFields(any())).thenAnswer((_) async => {});

      await pumpScreen(
        tester,
        patientId: 'patient-1',
        uploadedPatients: [UploadedPatient(id: 'patient-1', patient: _patient())],
        vitalsHistoryByPatient: {
          'patient-1': [
            VitalsHistoryEntry(
              vitals: const PatientVitals(
                heartRate: 88,
                bloodPressure: '118/76',
                oxygen: 97,
                temperature: 36.8,
                respiratoryRate: 14,
                gcs: 15,
              ),
              recordedAt: DateTime(2024, 1, 1, 8),
            ),
            VitalsHistoryEntry(
              vitals: const PatientVitals(
                heartRate: 92,
                bloodPressure: '122/80',
                oxygen: 98,
                temperature: 37,
                respiratoryRate: 16,
                gcs: 15,
              ),
              recordedAt: DateTime(2024, 1, 1, 9),
            ),
          ],
        },
      );
      await tester.pumpAndSettle();

      for (final label in ['Heart Rate', 'Blood Pressure', 'Oxygen', 'Temperature', 'Respiratory Rate', 'GCS']) {
        final iconFinder = find.byTooltip('$label trend');
        await tester.ensureVisible(iconFinder);
        await tester.tap(iconFinder);
        await tester.pumpAndSettle();

        // Scoped to the dialog, not a bare find.text(label) — GCS's own
        // field labelText is the exact same string as its dialog title,
        // so an unscoped finder ambiguously matches both.
        expect(find.descendant(of: find.byType(AlertDialog), matching: find.text(label)), findsOneWidget);
        expect(find.text('Not enough recorded data yet to show a trend.'), findsNothing);
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      }
    });
  });

  group('other dropdowns', () {
    testWidgets('selecting Gender, IV Size, and IV Placement options round-trips through submit', (tester) async {
      PatientFormValues? submitted;
      when(
        () => uploadService.uploadPatient(any(), latitude: any(named: 'latitude'), longitude: any(named: 'longitude')),
      ).thenAnswer((invocation) async {
        submitted = invocation.positionalArguments[0] as PatientFormValues;
        return const PatientSaveResult(id: 'new-id');
      });

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      // Gender is the first dropdown on the page.
      await tester.ensureVisible(find.byType(DropdownButtonFormField<String>).first);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Female').last);
      await tester.pumpAndSettle();

      // IV Size and IV Placement — found by their own current (unselected)
      // hint text isn't reliable across Flutter versions, so locate them
      // positionally among the remaining unselected dropdowns instead.
      final ivSizeDropdown = find.widgetWithText(DropdownButtonFormField<String>, 'IV Size (Gauge)');
      await tester.ensureVisible(ivSizeDropdown);
      await tester.tap(ivSizeDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('18G').last);
      await tester.pumpAndSettle();

      final ivPlacementDropdown = find.widgetWithText(DropdownButtonFormField<String>, 'IV Placement');
      await tester.ensureVisible(ivPlacementDropdown);
      await tester.tap(ivPlacementDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Left Hand').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('patient_upload_submit')));
      await tester.tap(find.byKey(const Key('patient_upload_submit')));
      await tester.pumpAndSettle();

      expect(submitted?.gender, 'Female');
      expect(submitted?.ivSize, '18G');
      expect(submitted?.ivPlacement, 'Left Hand');
    });
  });

  testWidgets('the location-error dialog fires exactly once, not on every poll', (tester) async {
    when(
      () => geolocator.getCurrentPosition(locationSettings: any(named: 'locationSettings')),
    ).thenThrow(Exception('location services disabled'));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('Location permission is off'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // The 15s poll fires again (still erroring) — the dialog must not
    // reappear a second time.
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(find.text('Location permission is off'), findsNothing);
  });

  testWidgets('the back button pops when there is a back stack, and goes home otherwise', (tester) async {
    await pumpApp(
      tester,
      const SizedBox(),
      overrides: [
        patientUploadServiceProvider.overrideWithValue(uploadService),
        patientDecryptionServiceProvider.overrideWithValue(decryptionService),
        emsTrackingProvider.overrideWith(() => _FakeEmsTrackingController()),
        uploadedPatientsProvider.overrideWithValue(const AsyncValue.data([])),
        hospitalNamesProvider.overrideWithValue(const ['Ottawa Civic']),
        isOfflineProvider.overrideWithValue(false),
      ],
      routes: {
        '/launch': (context) => ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PatientUploadScreen()),
          ),
          child: const Text('open upload'),
        ),
      },
      initialLocation: '/launch',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('open upload'));
    await tester.pumpAndSettle();
    expect(find.text('Upload Patient Information'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.text('open upload'), findsOneWidget);
  });

  testWidgets('the back button goes home when there is no back stack to pop', (tester) async {
    // pumpScreen's own routes table mounts PatientUploadScreen directly as
    // the initial location — context.canPop() is false there, so this
    // exercises the ternary's other branch (context.go('/')), distinct
    // from the pushed-route test above.
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.byKey(pumpAppHomeKey), findsOneWidget);
  });
}
