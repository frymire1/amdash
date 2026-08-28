/// Every app's real deployed hosting URL — mirrors
/// `libs/auth/src/lib/app-urls.ts`. Used by [AccessDeniedScreen] to link a
/// locked-out user straight to whichever app their actual role(s) grant.
class AppUrls {
  // physician/ems migrated from Firebase Hosting to Cloud Run (default
  // *.run.app URLs, confirmed live before these were updated). admin
  // hasn't migrated yet — still Firebase Hosting until that stage lands.
  static const physician = 'https://physician-web-577422583971.northamerica-northeast2.run.app';
  static const ems = 'https://ems-web-577422583971.northamerica-northeast2.run.app';
  static const admin = 'https://amdash-admin-dev.web.app';
}
