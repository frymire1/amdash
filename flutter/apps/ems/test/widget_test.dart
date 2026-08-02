// EmsApp initializes Firebase in main() before runApp(), so it can't be
// pumped directly in a widget test without mocking firebase_core's platform
// channels — deferred to Phase 1 alongside real screen coverage.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder — Firebase-backed widget tests land in Phase 1', () {
    expect(1 + 1, 2);
  });
}
