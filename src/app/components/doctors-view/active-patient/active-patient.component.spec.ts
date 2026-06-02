import { ComponentFixture, TestBed } from '@angular/core/testing';

import { ActivePatientComponent } from './active-patient.component';

describe('ActivePatientComponent', () => {
  let component: ActivePatientComponent;
  let fixture: ComponentFixture<ActivePatientComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ActivePatientComponent]
    })
    .compileComponents();
    
    fixture = TestBed.createComponent(ActivePatientComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
