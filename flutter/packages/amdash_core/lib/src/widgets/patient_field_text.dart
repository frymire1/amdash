import 'package:flutter/material.dart';

import '../models/patient.dart';

/// Renders a `PatientField` (patient.name/healthcareNumber) as text, with
/// a small inline spinner replacing it while an encrypted field is still
/// being decrypted — matches the small `strokeWidth: 2` spinner used
/// throughout the apps' buttons, rather than a plain "Decrypting…" text
/// flash. Centralized here once rather than hand-rolled differently across
/// patient_card.dart/patient_viewer.dart/patient_summary_card.dart's
/// several call sites — the resolved/blank/pending states are the same
/// tri-state [PatientFieldDisplay.display] already models, just with a
/// widget instead of a plain string for the pending case.
class PatientFieldText extends StatelessWidget {
  const PatientFieldText(this.field, {super.key, this.style, this.prefix = '', this.notAddedText = 'Not added yet'});

  final PatientField field;
  final TextStyle? style;

  /// Prepended to the resolved/blank text only (e.g. `'Healthcare #: '`) —
  /// not shown next to the pending spinner, which needs no label of its
  /// own beyond "Decrypting…".
  final String prefix;
  final String notAddedText;

  @override
  Widget build(BuildContext context) {
    if (field.plaintext == null) {
      final color = style?.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: color)),
          const SizedBox(width: 6),
          Text('Decrypting…', style: style),
        ],
      );
    }
    return Text('$prefix${field.display(notAddedText: notAddedText)}', style: style);
  }
}
