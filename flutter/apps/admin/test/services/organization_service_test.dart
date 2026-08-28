import 'package:admin/services/organization_service.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('organizationsProvider', () {
    test('lists every organization across every org, ordered by name', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('organizations').add({'name': 'Zeta EMS', 'country': 'CA'});
      await firestore.collection('organizations').add({'name': 'Alpha EMS', 'country': 'US'});

      final container = ProviderContainer(overrides: [firestoreProvider.overrideWithValue(firestore)]);
      addTearDown(container.dispose);

      final orgs = await container.read(organizationsProvider.future);
      expect(orgs.map((o) => o.name), ['Alpha EMS', 'Zeta EMS']);
    });

    test('an empty collection yields an empty list', () async {
      final firestore = FakeFirebaseFirestore();
      final container = ProviderContainer(overrides: [firestoreProvider.overrideWithValue(firestore)]);
      addTearDown(container.dispose);

      final orgs = await container.read(organizationsProvider.future);
      expect(orgs, isEmpty);
    });
  });
}
