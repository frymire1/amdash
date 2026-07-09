import { Route } from '@angular/router';
import { HomeComponent } from './components/home/home.component';
import { PatientUploadComponent } from './components/patient-upload/patient-upload.component';

export const appRoutes: Route[] = [
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
];
