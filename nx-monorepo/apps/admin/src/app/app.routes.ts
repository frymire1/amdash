import { Route } from '@angular/router';
import { AccessDeniedComponent, adminGuard, authGuard, guestGuard, LoginComponent, UserSettingsComponent } from '@amdash/auth';
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
