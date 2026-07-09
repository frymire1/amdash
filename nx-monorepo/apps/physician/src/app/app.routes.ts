import { Route } from '@angular/router';
import { MainViewComponent } from './components/main-view/main-view.component';

export const appRoutes: Route[] = [
  {
    path: '',
    redirectTo: 'physician',
    pathMatch: 'full',
  },
  {
    path: 'physician',
    component: MainViewComponent,
  },
];
