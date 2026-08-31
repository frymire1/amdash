import 'models/user_profile.dart';

/// Every app's real deployed hosting URL — mirrors
/// `libs/auth/src/lib/app-urls.ts`. Used by [AccessDeniedScreen] and
/// [LoginScreen]'s wrong-app step to link a locked-out user straight to
/// whichever app their actual role(s) grant.
class AppUrls {
  // All 3 migrated from Firebase Hosting to Cloud Run (default *.run.app
  // URLs, each confirmed live before its own entry was updated here).
  static const physician = 'https://physician-web-577422583971.northamerica-northeast2.run.app';
  static const ems = 'https://ems-web-577422583971.northamerica-northeast2.run.app';
  static const admin = 'https://admin-web-577422583971.northamerica-northeast2.run.app';
}

/// A single "try this app instead" suggestion — [label] for the button,
/// [url] for what tapping it opens.
class AppLink {
  const AppLink(this.label, this.url);
  final String label;
  final String url;
}

/// Shared by [AccessDeniedScreen] (post-auth: a signed-in user with no
/// role for the current app) and [LoginScreen]'s wrong-app step
/// (pre-auth: `checkAccountStatus` already told the client this email's
/// account has no role for the current app) — same underlying question,
/// "which of AmDash's other apps does this role list actually grant?",
/// asked at two different points in the login flow. Kept as one function
/// so the two screens can never quietly drift apart on which roles map to
/// which app.
List<AppLink> matchingAppLinks(List<UserRole> roles) {
  final links = <AppLink>[];
  if (roles.contains(UserRole.physician) || roles.contains(UserRole.nurse)) {
    links.add(const AppLink('Physician app', AppUrls.physician));
  }
  if (roles.contains(UserRole.ems)) {
    links.add(const AppLink('EMS app', AppUrls.ems));
  }
  if (roles.contains(UserRole.admin) || roles.contains(UserRole.superAdmin)) {
    links.add(const AppLink('Admin app', AppUrls.admin));
  }
  return links;
}
