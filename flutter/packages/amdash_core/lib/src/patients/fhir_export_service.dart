import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Calls the `exportPatientFhirBundle` callable (functions/src/patients.ts)
/// and saves the returned FHIR R4 Bundle to disk as pretty-printed JSON —
/// shared by physician (read-only patient view) and EMS (right after
/// completing transport) rather than duplicated, same reasoning as
/// [vitalsHistoryProvider] living here instead of either app's private
/// lib. The callable itself re-checks everything that matters
/// (org opted in, patient actually completed, same-org caller) — this is
/// just the thin client-side wrapper plus the local save step, not a
/// second copy of that gating logic.
///
/// Every relevant Cloud Function in this app runs in this region — must
/// match `REGION` in `functions/src/shared.ts`.
const _functionsRegion = 'northamerica-northeast2';

/// Thrown by [exportPatientFhirBundle] instead of letting a raw
/// [FirebaseFunctionsException] leak to the UI layer — callers only need
/// to show [message], not branch on Firebase's own error codes.
class FhirExportException implements Exception {
  const FhirExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [exportPatientFhirBundle]'s return value — the raw [bundle] map is
/// included (not just [filePath]) specifically so a caller can surface a
/// real value pulled from the actual round-tripped response, rather than
/// just a generic "it worked" message with nothing to verify against.
class FhirExportResult {
  const FhirExportResult({required this.filePath, required this.bundle});

  /// The on-device path [FileSaver] reports the file was written to.
  final String filePath;

  /// The exact FHIR R4 Bundle the callable returned, decoded — the same
  /// data that was written to [filePath], handed back so a caller can
  /// inspect it directly instead of re-reading the file it just saved.
  final Map<String, Object?> bundle;
}

// The exact text of patients.ts's "not yet completed" HttpsError — matched
// below to retry specifically this failure, not every failed-precondition
// (export-disabled and no-organization shouldn't be retried; they'll never
// resolve on their own).
const _notYetCompletedMessage = "This patient's transport must be marked complete before it can be exported.";

// Diagnostic only, mirroring PatientUploadService.debugCallCount's own
// rationale (not console/print-based — that relays over the DWDS debug
// websocket and can drop messages under load, confirmed unreliable for
// this exact pipeline). EMS's own caller (patient_summary_card.dart) no
// longer gates the export behind a UI confirmation the way it originally
// did — it now runs automatically right after completing transport,
// against a widget that's expected to unmount shortly after (it drops out
// of the active-only patient list the instant transport completes) — so
// there's no guaranteed-still-around success/error Text a test could
// reliably scan for either. A test can read these directly, in-process,
// for the exact outcome of the most recent real export call regardless of
// what happened to the triggering widget by the time it resolves.
FhirExportResult? debugLastExportResult;
Object? debugLastExportError;

/// Fetches and saves the export in one step.
Future<FhirExportResult> exportPatientFhirBundle(FirebaseFunctions functions, String patientId) async {
  final callable = functions.httpsCallable('exportPatientFhirBundle');
  final Map<Object?, Object?> result;
  try {
    result = await _callWithCompletionRetry(callable, patientId);
  } on FirebaseFunctionsException catch (error) {
    final exception = FhirExportException(_messageFor(error));
    debugLastExportError = exception;
    throw exception;
  }

  final bundle = Map<String, Object?>.from(result['bundle'] as Map);
  final json = const JsonEncoder.withIndent('  ').convert(bundle);
  final bytes = Uint8List.fromList(utf8.encode(json));

  final filePath = await FileSaver.instance.saveFile(
    name: '$patientId-fhir-export',
    bytes: bytes,
    fileExtension: 'json',
    mimeType: MimeType.json,
  );

  final exportResult = FhirExportResult(filePath: filePath, bundle: bundle);
  debugLastExportResult = exportResult;
  return exportResult;
}

// Retries specifically the "not yet completed" precondition a few times —
// cheap insurance against this callable's own Admin SDK read landing on a
// momentarily-stale view of a just-completed patient (e.g. a cold Cloud
// Functions instance's Firestore client still warming up its connection).
// Most of what originally motivated a much larger retry budget here
// turned out to be a *different*, now-fixed bug on the client side (see
// patient_upload_service.dart's completeTransportConfirmed and
// home_screen.dart's own comment) that no amount of retrying this call
// could ever have papered over, since it was checking the wrong
// patient's status entirely — so this stays modest rather than long.
Future<Map<Object?, Object?>> _callWithCompletionRetry(HttpsCallable callable, String patientId) async {
  const maxAttempts = 3;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return (await callable.call<Map<Object?, Object?>>({'patientId': patientId})).data;
    } on FirebaseFunctionsException catch (error) {
      final isRetryableNotYetCompleted = error.code == 'failed-precondition' && error.message == _notYetCompletedMessage;
      if (!isRetryableNotYetCompleted || attempt == maxAttempts) rethrow;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
  // Unreachable — the loop above always either returns or rethrows on its
  // final attempt.
  throw StateError('unreachable');
}

/// Pulls the most recent value for a given LOINC-coded vital straight out
/// of an exported [FhirExportResult.bundle] — e.g. `loincCode: '8867-4'`
/// for heart rate. Bundle entries are in the same oldest-first order the
/// callable queried vitalsHistory in (patients.ts), so the *last* matching
/// Observation is the most recent reading, mirroring what the app itself
/// currently displays as this patient's vitals. Returns `null` if that
/// vital was never recorded (or isn't in the bundle at all) — callers
/// should treat that as "nothing to show," not an error.
num? latestObservationValue(Map<String, Object?> bundle, String loincCode) {
  final entries = bundle['entry'] as List?;
  if (entries == null) return null;

  num? latest;
  for (final entry in entries) {
    final resource = (entry as Map)['resource'] as Map?;
    if (resource?['resourceType'] != 'Observation') continue;
    final codings = ((resource!['code'] as Map?)?['coding'] as List?) ?? const [];
    final matches = codings.any((c) => (c as Map)['code'] == loincCode);
    if (!matches) continue;
    final value = (resource['valueQuantity'] as Map?)?['value'];
    if (value is num) latest = value;
  }
  return latest;
}

// The callable's own HttpsError messages (patients.ts's
// exportPatientFhirBundle) are already written to be shown directly, but
// 'failed-precondition' covers three distinct real cases there (export
// disabled, not yet completed, no organization) with three different
// messages — surfacing its actual message rather than a generic fallback
// is what makes each of those legible instead of collapsing them into one
// unhelpful string.
String _messageFor(FirebaseFunctionsException error) {
  return error.message ?? "Couldn't export this patient's FHIR record. Please try again.";
}

final fhirExportFunctionsProvider = Provider<FirebaseFunctions>((ref) {
  return FirebaseFunctions.instanceFor(region: _functionsRegion);
});

/// LOINC code for heart rate — must match `LOINC.heartRate` in
/// functions/src/fhir.ts. Exposed here so a caller doesn't need to
/// hardcode the same magic string a second time just to spot-check the
/// export's own content (see [latestObservationValue]).
const loincHeartRate = '8867-4';
