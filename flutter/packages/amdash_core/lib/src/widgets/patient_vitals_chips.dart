import 'package:flutter/material.dart';

import '../models/patient.dart';
import '../theme/app_theme.dart';

/// A row of small labeled chips summarizing a patient's latest vitals —
/// shared between EMS's and physician's patient list cards (previously
/// physician had its own private copy of this and EMS showed only heart
/// rate) so both apps present the same fields, in the same order, styled
/// the same way. Each field falls back to "Not added yet" via
/// [isProvidedValue] (EMS leaves required fields as the literal string
/// `'Unknown'` when left blank on upload).
class PatientVitalsChips extends StatelessWidget {
  const PatientVitalsChips({required this.vitals, super.key});

  final PatientVitals vitals;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _chip(context, 'GCS', vitals.gcs),
        _chip(context, 'Heart Rate', vitals.heartRate),
        _chip(context, 'Blood Pressure', vitals.bloodPressure),
        _chip(context, 'Oxygen', vitals.oxygen),
        _chip(context, 'Resp. Rate', vitals.respiratoryRate),
        _chip(context, 'Temp', vitals.temperature),
      ],
    );
  }

  Widget _chip(BuildContext context, String label, Object? value) {
    final provided = isProvidedValue(value);
    final palette = context.palette;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: palette.glassSurface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant)),
          Text(
            provided ? value.toString() : 'Not added yet',
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
