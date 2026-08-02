import 'package:amdash_core/amdash_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('isProvidedValue treats the EMS blank-field sentinel as not provided', () {
    expect(isProvidedValue(72), true);
    expect(isProvidedValue('120/80'), true);
    expect(isProvidedValue(''), false);
    expect(isProvidedValue('Unknown'), false);
    expect(isProvidedValue(null), false);
  });
}
