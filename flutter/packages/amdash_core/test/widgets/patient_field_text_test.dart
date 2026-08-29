import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pump_app.dart';

void main() {
  testWidgets('an unresolved (still-encrypted) field shows the decrypting spinner', (tester) async {
    final field = PatientField.fromFirestore({'__enc': 1, 'ciphertext': 'abc'});
    await pumpApp(tester, PatientFieldText(field));

    expect(find.text('Decrypting…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a resolved field shows the prefix + display text', (tester) async {
    final field = PatientField.resolved('Jordan Smith');
    await pumpApp(tester, PatientFieldText(field, prefix: 'Healthcare #: '));

    expect(find.text('Healthcare #: Jordan Smith'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a blank plaintext field falls back to notAddedText', (tester) async {
    final field = PatientField.fromFirestore('');
    await pumpApp(tester, PatientFieldText(field, notAddedText: 'Not added by EMS yet'));

    expect(find.text('Not added by EMS yet'), findsOneWidget);
  });
}
