import { Routes } from '@angular/router';
import { DoctorsViewComponent } from './components/doctors-view/doctors-view.component';

export const routes: Routes = [
  {
    path: '',
    redirectTo: 'physician',
    pathMatch: 'full'
  },
  {
    path: 'physician',
    component: DoctorsViewComponent
  }
];
