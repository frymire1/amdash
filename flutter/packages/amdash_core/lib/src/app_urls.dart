/// Every app's real deployed hosting URL — mirrors
/// `libs/auth/src/lib/app-urls.ts`. Used by [AccessDeniedScreen] to link a
/// locked-out user straight to whichever app their actual role(s) grant.
class AppUrls {
  static const physician = 'https://amdash-physician-dev.web.app';
  static const ems = 'https://amdash-ems-dev.web.app';
  static const admin = 'https://amdash-admin-dev.web.app';
}
