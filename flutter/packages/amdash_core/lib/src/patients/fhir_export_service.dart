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

/// Fetches and saves the export in one step. Returns the on-device path
/// [FileSaver] reports the file was written to (mainly useful for a
/// confirmation message — callers don't need to do anything else with
/// it).
Future<String> exportPatientFhirBundle(FirebaseFunctions functions, String patientId) async {
  final callable = functions.httpsCallable('exportPatientFhirBundle');
  final Map<Object?, Object?> result;
  try {
    result = (await callable.call<Map<Object?, Object?>>({'patientId': patientId})).data;
  } on FirebaseFunctionsException catch (error) {
    throw FhirExportException(_messageFor(error));
  }

  final bundle = result['bundle'];
  final json = const JsonEncoder.withIndent('  ').convert(bundle);
  final bytes = Uint8List.fromList(utf8.encode(json));

  return FileSaver.instance.saveFile(
    name: '$patientId-fhir-export',
    bytes: bytes,
    fileExtension: 'json',
    mimeType: MimeType.json,
  );
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
