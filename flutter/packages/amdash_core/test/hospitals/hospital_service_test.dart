import 'package:amdash_core/amdash_core.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() async {
    firestore = FakeFirebaseFirestore();
    await firestore.collection('hospitals').add({
      'name': 'Zeta Hospital',
      'organizationId': 'org-1',
      'latitude': 1.0,
      'longitude': 1.0,
    });
    await firestore.collection('hospitals').add({
      'name': 'Alpha Hospital',
      'organizationId': 'org-1',
      'latitude': 2.0,
      'longitude': 2.0,
    });
    await firestore.collection('hospitals').add({
      'name': 'Other Org Hospital',
      'organizationId': 'org-2',
      'latitude': 3.0,
      'longitude': 3.0,
    });
  });

  // Even a `Stream.value(x)` override only delivers its event on the next
  // microtask, never synchronously within the same tick as subscribing
  // (a Dart Stream contract, not a bug) — so `hospitalsProvider`'s own
  // `ref.watch(userProfileProvider)` can genuinely observe it still
  // `AsyncLoading` on the very first build, race ahead using a stale
  // `valueOrNull == null`, and then get disposed mid-flight and rebuilt
  // once userProfileProvider's override actually resolves. Confirmed for
  // real: this raced to a wrong-but-fast empty-list result in one case and
  // a genuine 30s hang ("disposed during loading state, yet no value could
  // be emitted") in another (see own_organization_service_test.dart's
  // identical fix). Awaiting userProfileProvider.future first — forcing it
  // to fully settle before hospitalsProvider is ever built — avoids the
  // race entirely rather than trying to work around its symptoms.
  Future<ProviderContainer> containerFor(UserProfile? profile) async {
    final container = ProviderContainer(
      overrides: [
        firestoreProvider.overrideWithValue(firestore),
        userProfileProvider.overrideWith((ref) => Stream.value(profile)),
      ],
    );
    await container.read(userProfileProvider.future);
    return container;
  }

  group('hospitalsProvider', () {
    test('yields an empty list while the profile has not loaded yet', () async {
      final container = await containerFor(null);
      addTearDown(container.dispose);

      final hospitals = await container.read(hospitalsProvider.future);
      expect(hospitals, isEmpty);
    });

    test('a non-super-admin with no organizationId yet sees no hospitals', () async {
      const profile = UserProfile(role: [UserRole.physician]);
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      final hospitals = await container.read(hospitalsProvider.future);
      expect(hospitals, isEmpty);
    });

    test('a non-super-admin is scoped to their own organizationId, ordered by name', () async {
      const profile = UserProfile(role: [UserRole.physician], organizationId: 'org-1');
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      final hospitals = await container.read(hospitalsProvider.future);
      expect(hospitals.map((h) => h.name), ['Alpha Hospital', 'Zeta Hospital']);
      expect(hospitals.every((h) => h.organizationId == 'org-1'), true);
    });

    test('a super-admin sees every hospital across every organization, ordered by name', () async {
      const profile = UserProfile(role: [UserRole.superAdmin], organizationId: 'org-1');
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      final hospitals = await container.read(hospitalsProvider.future);
      expect(hospitals.map((h) => h.name), ['Alpha Hospital', 'Other Org Hospital', 'Zeta Hospital']);
    });
  });

  group('hospitalNamesProvider', () {
    test('derives just the names from hospitalsProvider', () async {
      const profile = UserProfile(role: [UserRole.physician], organizationId: 'org-1');
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      await container.read(hospitalsProvider.future);
      final names = container.read(hospitalNamesProvider);
      expect(names, ['Alpha Hospital', 'Zeta Hospital']);
    });

    test('empty before hospitalsProvider has resolved', () async {
      final container = await containerFor(null);
      addTearDown(container.dispose);

      expect(container.read(hospitalNamesProvider), isEmpty);
    });
  });
}
