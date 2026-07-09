import { ComponentFixture, TestBed } from '@angular/core/testing';

import { PatientViewerComponent } from './patient-viewer.component';

describe('PatientViewerComponent', () => {
  let component: PatientViewerComponent;
  let fixture: ComponentFixture<PatientViewerComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [PatientViewerComponent]
    })
    .compileComponents();
    
    fixture = TestBed.createComponent(PatientViewerComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
