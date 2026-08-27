import 'package:web/web.dart' as web;

/// A full browser reload — see `reload_page.dart` for why `AuthService`
/// needs this after every sign-out, not a plain in-app navigation.
void reloadPage() {
  web.window.location.reload();
}
