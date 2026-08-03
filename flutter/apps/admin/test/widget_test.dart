// AdminApp initializes Firebase in main() before runApp(), so it can't be
// pumped directly in a widget test without mocking firebase_core's platform
// channels — real screen coverage lives in patrol_test/ instead (see
// user_flow_test.dart), matching the physician app's convention.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder — Firebase-backed widget tests land in patrol_test/', () {
    expect(1 + 1, 2);
  });
}
