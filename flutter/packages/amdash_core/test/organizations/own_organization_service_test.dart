import 'package:amdash_core/amdash_core.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeFirebaseFirestore firestore;

  setUp(() {
    firestore = FakeFirebaseFirestore();
  });

  // See hospital_service_test.dart's identical helper for why
  // userProfileProvider.future is awaited before the container is handed
  // back — confirmed for real that skipping this races
  // ownOrganizationProvider's own `ref.watch(userProfileProvider)` against
  // userProfileProvider's override still settling, which for this provider
  // specifically manifested as a genuine 30s hang (StreamProviderElement
  // disposed mid-build, "yet no value could be emitted"), not just a
  // wrong-but-fast answer.
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

  group('ownOrganizationProvider', () {
    test('yields null when the caller has no organizationId', () async {
      const profile = UserProfile(role: [UserRole.physician]);
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      final org = await container.read(ownOrganizationProvider.future);
      expect(org, isNull);
    });

    test('yields null while the profile has not loaded yet', () async {
      final container = await containerFor(null);
      addTearDown(container.dispose);

      final org = await container.read(ownOrganizationProvider.future);
      expect(org, isNull);
    });

    test('listens on the caller\'s own organization doc once organizationId is known', () async {
      await firestore.collection('organizations').doc('org-1').set({
        'name': 'Toronto EMS',
        'fhirExportEnabled': true,
      });
      const profile = UserProfile(role: [UserRole.ems], organizationId: 'org-1');
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      final org = await container.read(ownOrganizationProvider.future);
      expect(org?.id, 'org-1');
      expect(org?.name, 'Toronto EMS');
      expect(org?.fhirExportEnabled, true);
    });

    test('yields null if the referenced organization doc does not exist', () async {
      const profile = UserProfile(role: [UserRole.ems], organizationId: 'missing-org');
      final container = await containerFor(profile);
      addTearDown(container.dispose);

      final org = await container.read(ownOrganizationProvider.future);
      expect(org, isNull);
    });
  });
}
