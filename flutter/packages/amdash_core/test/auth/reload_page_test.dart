import 'package:amdash_core/src/auth/reload_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reloadPage() is a no-op outside a browser (the stub variant this test target actually compiles in)', () {
    // flutter test runs on the Dart VM, where dart.library.html isn't
    // available — reload_page.dart's conditional export always resolves
    // to reload_page_stub.dart here, never reload_page_web.dart (which
    // needs a real browser and is exercised by the Web e2e suite instead;
    // see AuthService.signOut's own doc comment for why this split exists
    // at all). Nothing to assert beyond "doesn't throw" — it's a true
    // no-op by design.
    expect(reloadPage, returnsNormally);
  });
}
