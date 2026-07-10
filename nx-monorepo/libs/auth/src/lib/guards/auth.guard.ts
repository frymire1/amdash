import { inject } from '@angular/core';
import { toObservable } from '@angular/core/rxjs-interop';
import { CanActivateFn, Router } from '@angular/router';
import { filter, map, take } from 'rxjs';
import { AuthService } from '../services/auth.service';
import { UserProfileService } from '../services/user-profile.service';

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

export const adminGuard: CanActivateFn = () => {
  const userProfileService = inject(UserProfileService);
  const router = inject(Router);

  return toObservable(userProfileService.loading).pipe(
    filter((loading) => !loading),
    take(1),
    map(() => userProfileService.profile()?.role === 'admin' || router.parseUrl('/access-denied')),
  );
};
