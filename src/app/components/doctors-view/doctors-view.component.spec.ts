import { ComponentFixture, TestBed } from '@angular/core/testing';

import { DoctorsViewComponent } from './doctors.component';

describe('DoctorsComponent', () => {
  let component: DoctorsViewComponent;
  let fixture: ComponentFixture<DoctorsViewComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [DoctorsViewComponent]
    })
    .compileComponents();
    
    fixture = TestBed.createComponent(DoctorsViewComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
