import { Route } from '@angular/router';
import { AccessDeniedComponent, authGuard, emsAppGuard, guestGuard, LoginComponent, UserSettingsComponent } from '@amdash/auth';
import { HomeComponent } from './components/home/home.component';
import { PatientUploadComponent } from './components/patient-upload/patient-upload.component';

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
    canActivateChild: [authGuard, emsAppGuard],
    children: [
      {
        path: '',
        component: HomeComponent,
      },
      {
        path: 'upload',
        component: PatientUploadComponent,
      },
      {
        path: 'upload/:id',
        component: PatientUploadComponent,
      },
    ],
  },
];
