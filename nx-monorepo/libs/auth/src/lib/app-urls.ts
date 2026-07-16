// Every app's real deployed hosting URL — used by AccessDeniedComponent to
// link a locked-out user straight to whichever app their actual role(s)
// grant them.
export const APP_URLS = {
  physician: 'https://amdash-physician-dev.web.app',
  ems: 'https://amdash-ems-dev.web.app',
  admin: 'https://amdash-admin-dev.web.app',
} as const;
