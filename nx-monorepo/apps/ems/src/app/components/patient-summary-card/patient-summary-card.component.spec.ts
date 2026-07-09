import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';

import { PatientSummaryCardComponent } from './patient-summary-card.component';

describe('PatientSummaryCardComponent', () => {
  let component: PatientSummaryCardComponent;
  let fixture: ComponentFixture<PatientSummaryCardComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [PatientSummaryCardComponent],
      providers: [provideRouter([])],
    }).compileComponents();

    fixture = TestBed.createComponent(PatientSummaryCardComponent);
    component = fixture.componentInstance;
    component.uploaded = {
      id: 'test-id',
      patient: {
        name: 'John Doe',
        gender: 'Male',
        age: 45,
        healthcareNumber: 'HC-123456789',
        vitals: { heartRate: 72, bloodPressure: '120/80', oxygen: 98, temperature: 36.7 },
        location: { latitude: 40.7128, longitude: -74.006, address: 'New York, NY' },
      },
    };
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
