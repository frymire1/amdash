import { Route } from '@angular/router';
import { authGuard, guestGuard, LoginComponent, profileCompleteGuard, UserSettingsComponent } from '@amdash/auth';
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
    path: '',
    canActivateChild: [authGuard, profileCompleteGuard],
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
