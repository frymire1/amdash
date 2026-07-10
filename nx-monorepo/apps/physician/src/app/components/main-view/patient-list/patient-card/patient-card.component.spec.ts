import { ComponentFixture, TestBed } from '@angular/core/testing';

import { PatientCardComponent } from './patient-card.component';

describe('PatientCardComponent', () => {
  let component: PatientCardComponent;
  let fixture: ComponentFixture<PatientCardComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [PatientCardComponent]
    })
    .compileComponents();

    fixture = TestBed.createComponent(PatientCardComponent);
    component = fixture.componentInstance;
    fixture.componentRef.setInput('patient', {
      name: 'John Doe',
      gender: 'Male',
      age: 45,
      healthcareNumber: 'HC-123456789',
      vitals: {
        heartRate: 72,
        bloodPressure: '120/80',
        oxygen: 98,
        temperature: 36.7
      },
      location: {
        latitude: 40.7128,
        longitude: -74.006,
        address: 'New York, NY'
      }
    });
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
