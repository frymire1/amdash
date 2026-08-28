/// Every app's real deployed hosting URL — mirrors
/// `libs/auth/src/lib/app-urls.ts`. Used by [AccessDeniedScreen] to link a
/// locked-out user straight to whichever app their actual role(s) grant.
class AppUrls {
  // All 3 migrated from Firebase Hosting to Cloud Run (default *.run.app
  // URLs, each confirmed live before its own entry was updated here).
  static const physician = 'https://physician-web-577422583971.northamerica-northeast2.run.app';
  static const ems = 'https://ems-web-577422583971.northamerica-northeast2.run.app';
  static const admin = 'https://admin-web-577422583971.northamerica-northeast2.run.app';
}
