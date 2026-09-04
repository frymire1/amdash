import 'dart:async';

import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/ems_alert_service.dart';
import '../services/patient_session_service.dart';
import '../widgets/battery_warning_banner.dart';
import '../widgets/patient_summary_card.dart';

/// Mirrors `home.component.ts`/`.html`. A `ConsumerStatefulWidget`, not
/// `ConsumerWidget` — needs `initState` as the "once per real
/// HomeScreen mount" hook for connectivity-alert registration below,
/// which a plain `build()` (re-run on every rebuild, not just mount)
/// can't offer.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Registers this device for EMS connectivity-loss push alerts
    // (functions/src/ems.ts) once per HomeScreen mount — automatic, not an
    // opt-in toggle (this is a safety net, not a preference; see
    // ems_alert_service.dart's own doc comment). Fire-and-forget: a failed
    // or dismissed permission prompt shouldn't block this screen's own
    // first frame, and registerForConnectivityAlerts already swallows its
    // own failures. valueOrNull?.uid is deliberately not asserted non-null
    // — this screen is only ever reached once signed in (see the router's
    // own guard chain), but a stray unauthenticated mount should silently
    // skip registration rather than crash.
    //
    // Skipped entirely on web: there's no production EMS web app (kept
    // only for this repo's own Chrome e2e coverage — see ems_test.dart's
    // header comment), so a real registration attempt here serves no
    // production purpose, and it's actively harmful in that e2e role —
    // confirmed for real: a first version that ran this unconditionally
    // broke ems_test.dart's own Chrome CI job with a missing
    // patient.fhirExport audit-log entry, evidently from Chromium's
    // requestPermission()/getToken() call (already known-broken for real
    // push registration — see incoming_patient_test.dart's identical
    // finding) tying up test/browser resources during this suite's
    // longest, most Firestore-heavy run.
    if (kIsWeb) return;
    final uid = ref.read(authStateProvider).valueOrNull?.uid;
    if (uid != null) {
      unawaited(ref.read(emsAlertServiceProvider).registerForConnectivityAlerts(uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    final uploadedPatients = ref.watch(uploadedPatientsProvider);

    // No Scaffold/NavBar of its own — this screen lives inside the app's
    // ShellRoute now, which owns those.
    return Column(
      children: [
          const OfflineBanner(),
          const BatteryWarningBanner(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              // Center + ConstrainedBox — same pattern as
              // patient_upload_screen.dart's form, so the dashboard's list
              // and the upload form line up at the same width instead of
              // the list stretching edge-to-edge on wide screens.
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(
                        width: double.infinity,
                        child: Text(
                          'EMS Dashboard',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const SizedBox(
                        width: double.infinity,
                        child: Text(
                          'Upload patient information to hand off to the receiving physician.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: FilledButton.icon(
                          onPressed: () => context.push('/upload'),
                          icon: const Icon(Icons.person_add),
                          label: const Text('Add Patient'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      uploadedPatients.when(
                        // .stretch so each PatientSummaryCard fills the same
                        // 720px width as patient_upload_screen.dart's form
                        // sections, instead of shrink-wrapping to its own
                        // content width under the outer Column's .start.
                        data: (patients) => patients.isEmpty
                            ? const EmptyState(
                                title: 'No patients uploaded yet',
                                subtitle: 'Tap "Add Patient" above to get started',
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                // Keyed by patient id — without this, removing
                                // one card (e.g. a patient dropping out of
                                // this active-only list right after Complete
                                // Transport) makes Flutter's unkeyed-list
                                // reconciliation reuse every *later* card's
                                // State object for the next patient that
                                // shifts into its old position, silently
                                // swapping which patient `widget.uploaded`
                                // refers to mid-callback in
                                // _PatientSummaryCardState — `mounted` stays
                                // true throughout, so none of its own
                                // `if (!mounted) return;` guards catch it.
                                // Confirmed for real via a genuine Patrol e2e
                                // failure: completeTransportConfirmed
                                // confirmed the *correct* patient's write via
                                // a live server-acknowledged snapshot, yet the
                                // chained FHIR export attempt right after kept
                                // failing with "must be marked complete" no
                                // matter how long that export call retried —
                                // because by then `widget.uploaded.id` had
                                // silently become a *different*, still-active
                                // patient's id.
                                children: [
                                  for (final uploaded in patients)
                                    PatientSummaryCard(key: ValueKey(uploaded.id), uploaded: uploaded),
                                ],
                              ),
                        loading: () => const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        error: (error, stackTrace) => Text(
                          'Failed to load patients: $error',
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
  }
}
