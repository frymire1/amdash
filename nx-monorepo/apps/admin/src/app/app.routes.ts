import { Route } from '@angular/router';
import { adminGuard, authGuard, guestGuard, LoginComponent, UserSettingsComponent } from '@amdash/auth';
import { AccessDeniedComponent } from './components/access-denied/access-denied.component';
import { UserManagementComponent } from './components/user-management/user-management.component';

export const appRoutes: Route[] = [
  {
    path: 'login',
    component: LoginComponent,
    canActivate: [guestGuard],
  },
  {
    path: 'user-settings',
    component: UserSettingsComponent,
    canActivate: [authGuard],
  },
  {
    path: 'access-denied',
    component: AccessDeniedComponent,
    canActivate: [authGuard],
  },
  {
    path: '',
    canActivateChild: [authGuard, adminGuard],
    children: [
      {
        path: '',
        component: UserManagementComponent,
      },
    ],
  },
];
