import { Route } from '@angular/router';
import {
  AccessDeniedComponent,
  adminGuard,
  authGuard,
  guestGuard,
  LoginComponent,
  superAdminGuard,
  UserSettingsComponent,
} from '@amdash/auth';
import { UserManagementComponent } from './components/user-management/user-management.component';
import { HospitalManagementComponent } from './components/hospital-management/hospital-management.component';
import { OrganizationManagementComponent } from './components/organization-management/organization-management.component';
import { landingGuard } from './guards/landing.guard';

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
    canActivateChild: [authGuard],
    children: [
      { path: '', pathMatch: 'full', canActivate: [landingGuard], component: UserManagementComponent },
      { path: 'users', component: UserManagementComponent, canActivate: [adminGuard] },
      { path: 'hospitals', component: HospitalManagementComponent, canActivate: [adminGuard] },
      { path: 'organizations', component: OrganizationManagementComponent, canActivate: [superAdminGuard] },
    ],
  },
];
