import { Route } from '@angular/router';
import {
  authGuard,
  guestGuard,
  LoginComponent,
  physicianAppGuard,
  profileCompleteGuard,
  UserSettingsComponent,
} from '@amdash/auth';
import { AccessDeniedComponent } from './components/access-denied/access-denied.component';
import { MainViewComponent } from './components/main-view/main-view.component';

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
    canActivateChild: [authGuard, profileCompleteGuard, physicianAppGuard],
    children: [
      {
        path: '',
        redirectTo: 'physician',
        pathMatch: 'full',
      },
      {
        path: 'physician',
        component: MainViewComponent,
      },
    ],
  },
];
