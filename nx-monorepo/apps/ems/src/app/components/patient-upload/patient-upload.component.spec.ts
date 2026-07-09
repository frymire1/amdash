import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';

import { PatientUploadComponent } from './patient-upload.component';
import { PatientUploadService } from '../../services/patient-upload.service';

describe('PatientUploadComponent', () => {
  let component: PatientUploadComponent;
  let fixture: ComponentFixture<PatientUploadComponent>;
  let uploadCalled = false;

  beforeEach(async () => {
    uploadCalled = false;

    await TestBed.configureTestingModule({
      imports: [PatientUploadComponent],
      providers: [
        provideRouter([]),
        {
          provide: PatientUploadService,
          useValue: {
            uploadPatient: async () => {
              uploadCalled = true;
              return 'test-id';
            },
          },
        },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(PatientUploadComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should not submit an invalid form', async () => {
    await component.onSubmit();
    expect(uploadCalled).toBe(false);
    expect(component.patientForm.touched).toBe(true);
  });
});
