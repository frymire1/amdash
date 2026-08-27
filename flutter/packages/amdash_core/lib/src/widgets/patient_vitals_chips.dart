import 'package:flutter/material.dart';

import '../models/patient.dart';
import '../patients/vitals_status.dart';
import '../theme/app_theme.dart';

/// A row of small labeled chips summarizing a patient's latest vitals —
/// shared between EMS's and physician's patient list cards (previously
/// physician had its own private copy of this and EMS showed only heart
/// rate) so both apps present the same fields, in the same order, styled
/// the same way. Each field falls back to "Not added yet" via
/// [isProvidedValue] (EMS leaves required fields as the literal string
/// `'Unknown'` when left blank on upload). A vital outside its typical
/// range shades that one chip's fill/outline (see [VitalStatus]) — text
/// color is never touched.
class PatientVitalsChips extends StatelessWidget {
  const PatientVitalsChips({required this.vitals, super.key});

  final PatientVitals vitals;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _chip(context, 'GCS', vitals.gcs, gcsStatus(vitals.gcs)),
        // Suffix matters here, not just cosmetically: EMS's e2e suite
        // asserts the exact text "95 bpm" on this list card after editing
        // heart rate (ems_test.dart/patient_upload_flow_test.dart) — a
        // real CI failure caught this chip silently dropping the unit
        // when this widget replaced EMS's old plain-text heart rate
        // display.
        _chip(context, 'Heart Rate', vitals.heartRate, heartRateStatus(vitals.heartRate), suffix: 'bpm'),
        _chip(context, 'Blood Pressure', vitals.bloodPressure, bloodPressureStatus(vitals.bloodPressure)),
        _chip(context, 'Oxygen', vitals.oxygen, oxygenStatus(vitals.oxygen), suffix: '%'),
        _chip(
          context,
          'Resp. Rate',
          vitals.respiratoryRate,
          respiratoryRateStatus(vitals.respiratoryRate),
          suffix: 'breaths/min',
        ),
        _chip(context, 'Temp', vitals.temperature, temperatureStatus(vitals.temperature), suffix: '°C'),
      ],
    );
  }

  Widget _chip(BuildContext context, String label, Object? value, VitalStatus? status, {String? suffix}) {
    final provided = isProvidedValue(value);
    final text = provided ? (suffix == null ? '$value' : '$value $suffix') : 'Not added yet';
    final palette = context.palette;
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor = status == null ? null : vitalStatusColor(palette, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: statusColor == null ? palette.glassSurface : statusColor.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: statusColor == null ? palette.border : darkenForOutline(statusColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant)),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontStyle: provided ? FontStyle.normal : FontStyle.italic,
              color: provided ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
