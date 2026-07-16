import { Route } from '@angular/router';
import {
  AccessDeniedComponent,
  authGuard,
  guestGuard,
  LoginComponent,
  physicianAppGuard,
  UserSettingsComponent,
  WorkLocationComponent,
  workLocationGuard,
} from '@amdash/auth';
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
    path: 'work-location',
    component: WorkLocationComponent,
    canActivate: [authGuard, physicianAppGuard],
  },
  {
    path: 'access-denied',
    component: AccessDeniedComponent,
    canActivate: [authGuard],
  },
  {
    path: '',
    canActivateChild: [authGuard, physicianAppGuard, workLocationGuard],
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
