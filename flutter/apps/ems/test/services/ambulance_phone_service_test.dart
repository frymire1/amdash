import 'package:ems/services/ambulance_phone_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AmbulancePhoneService', () {
    test('read returns null when nothing has ever been saved', () async {
      final service = AmbulancePhoneService();
      expect(await service.read(), isNull);
    });

    test('save then read round-trips the value', () async {
      final service = AmbulancePhoneService();
      await service.save('555-0123');
      expect(await service.read(), '555-0123');
    });

    test('a later save overwrites the earlier one', () async {
      final service = AmbulancePhoneService();
      await service.save('555-0123');
      await service.save('555-9999');
      expect(await service.read(), '555-9999');
    });
  });

  group('ambulancePhoneProvider', () {
    test('reflects the persisted value via ambulancePhoneServiceProvider', () async {
      SharedPreferences.setMockInitialValues({'amdash-ems-ambulance-phone': '555-0123'});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(await container.read(ambulancePhoneProvider.future), '555-0123');
    });

    test('null when nothing has been saved', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(await container.read(ambulancePhoneProvider.future), isNull);
    });
  });
}
