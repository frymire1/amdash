import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { provideRouter } from '@angular/router';

import { PatientUploadComponent } from './patient-upload.component';
import { PatientUploadService } from '../../services/patient-upload.service';
import { PatientSessionService } from '../../services/patient-session.service';

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
        {
          provide: PatientSessionService,
          useValue: { uploadedPatients: signal([]), findUploadedPatient: () => undefined },
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

  // Every field is optional now, including location — see
  // PatientUploadComponent's patientForm.
  it('should submit an empty form', async () => {
    await component.onSubmit();
    expect(uploadCalled).toBe(true);
  });

  it('should not submit a form with an out-of-range value', async () => {
    component.patientForm.controls.age.setValue(-5);
    await component.onSubmit();
    expect(uploadCalled).toBe(false);
    expect(component.patientForm.touched).toBe(true);
  });
});
