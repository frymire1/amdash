import { ComponentFixture, TestBed } from '@angular/core/testing';
import { MAT_DIALOG_DATA, MatDialogRef } from '@angular/material/dialog';

import { ConfirmDialogComponent } from './confirm-dialog.component';

describe('ConfirmDialogComponent', () => {
  let component: ConfirmDialogComponent;
  let fixture: ComponentFixture<ConfirmDialogComponent>;
  let closedWith: boolean | undefined;

  beforeEach(async () => {
    closedWith = undefined;

    await TestBed.configureTestingModule({
      imports: [ConfirmDialogComponent],
      providers: [
        {
          provide: MatDialogRef,
          useValue: { close: (result: boolean) => (closedWith = result) },
        },
        {
          provide: MAT_DIALOG_DATA,
          useValue: { title: 'Delete patient?', message: 'Delete John Doe? This cannot be undone.' },
        },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(ConfirmDialogComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('closes with true on confirm', () => {
    component.onConfirm();
    expect(closedWith).toBe(true);
  });

  it('closes with false on cancel', () => {
    component.onCancel();
    expect(closedWith).toBe(false);
  });
});
