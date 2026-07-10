import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';

import { UserManagementComponent } from './user-management.component';
import { AdminService } from '../../services/admin.service';

describe('UserManagementComponent', () => {
  let component: UserManagementComponent;
  let fixture: ComponentFixture<UserManagementComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [UserManagementComponent],
      providers: [
        {
          provide: AdminService,
          useValue: {
            users: signal([]),
            loadingUsers: signal(false),
            refreshUsers: async () => undefined,
            setUserRole: async () => ({ uid: '1', email: 'a@b.com', role: 'ems' }),
          },
        },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(UserManagementComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});
