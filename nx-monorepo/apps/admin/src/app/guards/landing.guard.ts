import { inject } from '@angular/core';
import { toObservable } from '@angular/core/rxjs-interop';
import { CanActivateFn, Router } from '@angular/router';
import { UserProfileService } from '@amdash/auth';
import { filter, map, take } from 'rxjs';

// The default '' route has no single page every admin-app account should
// land on: an org-admin belongs on /users, a super-admin (who has no org
// and can't use /users or /hospitals — those are org-scoped) belongs on
// /organizations. adminGuard/superAdminGuard alone can't express "redirect
// to whichever of these applies," since a CanActivateFn either allows or
// redirects a single fixed destination — this picks the destination first.
export const landingGuard: CanActivateFn = () => {
  const userProfileService = inject(UserProfileService);
  const router = inject(Router);

  return toObservable(userProfileService.loading).pipe(
    filter((loading) => !loading),
    take(1),
    map(() => {
      const roles = userProfileService.profile()?.role ?? [];
      if (roles.includes('admin')) {
        return router.parseUrl('/users');
      }
      if (roles.includes('super-admin')) {
        return router.parseUrl('/organizations');
      }
      return router.parseUrl('/access-denied');
    }),
  );
};
