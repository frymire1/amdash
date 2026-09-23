import 'package:flutter_test/flutter_test.dart';
import 'package:physician/classes/active_ambulance_location.dart';

void main() {
  test('exposes every field passed to the constructor unchanged', () {
    const location = ActiveAmbulanceLocation(
      ambulanceId: 'Unit 5',
      latitude: 45.4,
      longitude: -75.7,
      isTransporting: true,
      updatedAtMs: 1000,
    );

    expect(location.ambulanceId, 'Unit 5');
    expect(location.latitude, 45.4);
    expect(location.longitude, -75.7);
    expect(location.isTransporting, true);
    expect(location.updatedAtMs, 1000);
  });
}
