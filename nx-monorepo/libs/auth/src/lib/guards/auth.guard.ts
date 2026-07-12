import { inject } from '@angular/core';
import { toObservable } from '@angular/core/rxjs-interop';
import { CanActivateFn, Router } from '@angular/router';
import { filter, map, take } from 'rxjs';
import { AuthService } from '../services/auth.service';
import { UserProfileService, UserRole } from '../services/user-profile.service';

export const authGuard: CanActivateFn = () => {
  const authService = inject(AuthService);
  const router = inject(Router);

  return toObservable(authService.initializing).pipe(
    filter((initializing) => !initializing),
    take(1),
    map(() => authService.isAuthenticated() || router.parseUrl('/login')),
  );
};

export const guestGuard: CanActivateFn = () => {
  const authService = inject(AuthService);
  const router = inject(Router);

  return toObservable(authService.initializing).pipe(
    filter((initializing) => !initializing),
    take(1),
    map(() => !authService.isAuthenticated() || router.parseUrl('/')),
  );
};

export const profileCompleteGuard: CanActivateFn = () => {
  const userProfileService = inject(UserProfileService);
  const router = inject(Router);

  return toObservable(userProfileService.loading).pipe(
    filter((loading) => !loading),
    take(1),
    map(() => !!userProfileService.profile()?.firstName || router.parseUrl('/user-settings')),
  );
};

// Builds a guard that only allows through users whose Firestore `role` is
// one of `allowedRoles`, redirecting everyone else (including users with no
// role assigned yet) to /access-denied.
function roleGuard(...allowedRoles: UserRole[]): CanActivateFn {
  return () => {
    const userProfileService = inject(UserProfileService);
    const router = inject(Router);

    return toObservable(userProfileService.loading).pipe(
      filter((loading) => !loading),
      take(1),
      map(() => {
        const role = userProfileService.profile()?.role;
        return (!!role && allowedRoles.includes(role)) || router.parseUrl('/access-denied');
      }),
    );
  };
}

export const adminGuard: CanActivateFn = roleGuard('admin');
export const physicianAppGuard: CanActivateFn = roleGuard('physician', 'nurse');
export const emsAppGuard: CanActivateFn = roleGuard('ems');
