import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';

import { PatientListComponent } from './patient-list.component';
import { PatientService } from '../../../services/patient.service';
import { EmsLocationService } from '../../../services/ems-location.service';

describe('PatientListComponent', () => {
  let component: PatientListComponent;
  let fixture: ComponentFixture<PatientListComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [PatientListComponent],
      providers: [
        {
          provide: PatientService,
          useValue: { patients: signal([]) },
        },
        {
          provide: EmsLocationService,
          useValue: { trackedPatientIds: signal(new Set()), isTracked: () => false },
        },
      ],
    })
    .compileComponents();

    fixture = TestBed.createComponent(PatientListComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
