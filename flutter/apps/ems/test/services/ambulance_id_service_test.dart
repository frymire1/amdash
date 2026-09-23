import 'package:ems/services/ambulance_id_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AmbulanceIdService', () {
    test('read returns null when nothing has ever been saved', () async {
      final service = AmbulanceIdService();
      expect(await service.read(), isNull);
    });

    test('save then read round-trips the value', () async {
      final service = AmbulanceIdService();
      await service.save('Unit 5');
      expect(await service.read(), 'Unit 5');
    });

    test('a later save overwrites the earlier one', () async {
      final service = AmbulanceIdService();
      await service.save('Unit 5');
      await service.save('Unit 9');
      expect(await service.read(), 'Unit 9');
    });
  });

  group('ambulanceIdProvider', () {
    test('reflects the persisted value via ambulanceIdServiceProvider', () async {
      SharedPreferences.setMockInitialValues({'amdash-ems-ambulance-id': 'Unit 5'});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(await container.read(ambulanceIdProvider.future), 'Unit 5');
    });

    test('null when nothing has been saved', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(await container.read(ambulanceIdProvider.future), isNull);
    });
  });
}
