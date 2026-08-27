import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/patient.dart';
import '../models/vitals_history_entry.dart';
import '../patients/vitals_history_service.dart';
import '../patients/vitals_status.dart';
import '../theme/app_theme.dart';
import 'vitals_trend_dialog.dart';

/// A titled card wrapping a `Wrap` of rows — the generic shape shared by
/// every read-only patient-detail card other than [PatientVitalsCard]
/// (which needs its own "Recorded {time}" subtitle).
class PatientInfoCard extends StatelessWidget {
  const PatientInfoCard({required this.title, required this.rows, super.key});

  final String title;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 12, children: rows),
          ],
        ),
      ),
    );
  }
}

/// A single labeled, bordered field — with a tappable trend-chart icon
/// (via [showVitalsTrendDialog]) once [trendSeries] is given and [history]
/// has more than one entry (a single reading isn't a trend). Falls back to
/// "Not added by EMS yet" via [isProvidedValue]. [status], when given,
/// shades the chip's fill/outline to flag a safe/moderate/danger reading —
/// text color is never touched, only the chip itself. Fields with no vital
/// range (Destination, IV Size, etc.) simply leave [status] null and get
/// the plain accent-stripe look.
class PatientInfoChip extends StatelessWidget {
  const PatientInfoChip(
    this.label,
    this.value, {
    this.suffix,
    this.trendSeries,
    this.history = const [],
    this.status,
    super.key,
  });

  final String label;
  final Object? value;
  final String? suffix;
  final List<VitalSeries>? trendSeries;
  final List<VitalsHistoryEntry> history;
  final VitalStatus? status;

  @override
  Widget build(BuildContext context) {
    final provided = isProvidedValue(value);
    final text = provided ? (suffix == null ? '$value' : '$value $suffix') : 'Not added by EMS yet';
    final palette = context.palette;
    final colorScheme = Theme.of(context).colorScheme;
    // Captured into a local so it promotes to non-null inside the onTap
    // closure below — a public field itself (unlike a private one, or a
    // plain method parameter) never promotes past a null check.
    final series = trendSeries;
    final showTrend = series != null && history.length > 1;
    final statusColor = status == null ? null : vitalStatusColor(palette, status!);
    return SizedBox(
      width: 200,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: statusColor == null ? palette.glassSurface : statusColor.withValues(alpha: 0.16),
          border: statusColor == null
              ? Border(left: BorderSide(color: AppColors.trackingAccent, width: 3))
              : Border.all(color: darkenForOutline(statusColor)),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label, style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant)),
                ),
                if (showTrend)
                  InkWell(
                    // Keyed (rather than found by ancestor/type) — a
                    // Row-typed ancestor search from this row's label text
                    // could also match an outer Row a caller wraps this
                    // chip in, pulling in every other vital's trend icon as
                    // a false-positive descendant match.
                    key: Key('vitals_trend_$label'),
                    onTap: () => showVitalsTrendDialog(
                      context,
                      title: label,
                      history: history,
                      series: series,
                      unit: suffix == null ? null : ' $suffix',
                    ),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(Icons.show_chart, size: 14, color: AppColors.trackingAccent),
                    ),
                  ),
              ],
            ),
            Text(
              text,
              style: TextStyle(
                fontStyle: provided ? FontStyle.normal : FontStyle.italic,
                color: provided ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Same shape as [PatientInfoCard], but the header carries a "Recorded
/// {time}" stamp from the latest [vitalsHistoryProvider] entry, and each
/// vital gets a trend-chart icon once there's more than one reading to
/// chart. Falls back to `patient.vitals` with no timestamp while history is
/// still loading, or for a patient that predates this feature (no history
/// entries exist for it at all).
class PatientVitalsCard extends ConsumerWidget {
  const PatientVitalsCard({required this.patient, super.key});

  final Patient patient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patientId = patient.id;
    final history = patientId == null
        ? const <VitalsHistoryEntry>[]
        : ref.watch(vitalsHistoryProvider(patientId)).valueOrNull ?? const [];
    final vitals = patient.vitals;
    final latestRecordedAt = history.isEmpty ? null : history.first.recordedAt;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Vital Signs', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Text(
                latestRecordedAt == null
                    ? 'No upload history recorded for this patient'
                    : 'Recorded ${DateFormat('MMM d, h:mm a').format(latestRecordedAt)}',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                PatientInfoChip(
                  'Heart Rate',
                  vitals.heartRate,
                  suffix: 'bpm',
                  history: history,
                  trendSeries: [VitalSeries(label: 'Heart Rate', selector: (v) => numOrNull(v.heartRate))],
                  status: heartRateStatus(vitals.heartRate),
                ),
                PatientInfoChip(
                  'Blood Pressure',
                  vitals.bloodPressure,
                  history: history,
                  trendSeries: [
                    VitalSeries(
                      label: 'Systolic',
                      selector: (v) => bloodPressurePart(v.bloodPressure, 0),
                      color: AppColors.trackingAccent,
                    ),
                    VitalSeries(label: 'Diastolic', selector: (v) => bloodPressurePart(v.bloodPressure, 1), color: AppColors.brand),
                  ],
                  status: bloodPressureStatus(vitals.bloodPressure),
                ),
                PatientInfoChip(
                  'Oxygen',
                  vitals.oxygen,
                  suffix: '%',
                  history: history,
                  trendSeries: [VitalSeries(label: 'Oxygen', selector: (v) => numOrNull(v.oxygen))],
                  status: oxygenStatus(vitals.oxygen),
                ),
                PatientInfoChip(
                  'Temperature',
                  vitals.temperature,
                  suffix: '°C',
                  history: history,
                  trendSeries: [VitalSeries(label: 'Temperature', selector: (v) => numOrNull(v.temperature))],
                  status: temperatureStatus(vitals.temperature),
                ),
                PatientInfoChip(
                  'Respiratory Rate',
                  vitals.respiratoryRate,
                  suffix: 'breaths/min',
                  history: history,
                  trendSeries: [VitalSeries(label: 'Respiratory Rate', selector: (v) => v.respiratoryRate)],
                  status: respiratoryRateStatus(vitals.respiratoryRate),
                ),
                PatientInfoChip(
                  'GCS',
                  vitals.gcs,
                  history: history,
                  trendSeries: [VitalSeries(label: 'GCS', selector: (v) => v.gcs)],
                  status: gcsStatus(vitals.gcs),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Treatment/medication narrative plus IV size/placement.
class PatientTreatmentCard extends StatelessWidget {
  const PatientTreatmentCard({required this.patient, super.key});

  final Patient patient;

  @override
  Widget build(BuildContext context) {
    final treatmentProvided = isProvidedValue(patient.treatment);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Treatment / Medication Given', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              treatmentProvided ? patient.treatment! : 'Not added by EMS yet',
              style: TextStyle(
                fontStyle: treatmentProvided ? FontStyle.normal : FontStyle.italic,
                color: treatmentProvided ? null : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                PatientInfoChip('IV Size', patient.ivSize),
                PatientInfoChip('IV Placement', patient.ivPlacement),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A titled card of plain text — used for free-text fields like patient
/// notes that don't fit [PatientInfoCard]'s chip-grid shape.
class PatientTextCard extends StatelessWidget {
  const PatientTextCard({required this.title, required this.text, super.key});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(text),
          ],
        ),
      ),
    );
  }
}
