import { ComponentFixture, TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { provideRouter } from '@angular/router';

import { UserSettingsComponent } from './user-settings.component';
import { UserProfileService } from '../services/user-profile.service';

describe('UserSettingsComponent', () => {
  let component: UserSettingsComponent;
  let fixture: ComponentFixture<UserSettingsComponent>;
  let saveCalled = false;

  function setup(initialProfile: { firstName: string; lastName: string } | null) {
    saveCalled = false;
    TestBed.resetTestingModule();

    return TestBed.configureTestingModule({
      imports: [UserSettingsComponent],
      providers: [
        provideRouter([]),
        {
          provide: UserProfileService,
          useValue: {
            profile: signal(initialProfile),
            saveProfile: async () => {
              saveCalled = true;
            },
          },
        },
      ],
    }).compileComponents();
  }

  beforeEach(async () => {
    await setup(null);

    fixture = TestBed.createComponent(UserSettingsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('should not save with an invalid form', async () => {
    await component.onSubmit();
    expect(saveCalled).toBe(false);
    expect(component.settingsForm.touched).toBe(true);
  });

  it('prefills the form with the existing profile', async () => {
    await setup({ firstName: 'Ada', lastName: 'Lovelace' });

    fixture = TestBed.createComponent(UserSettingsComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();

    expect(component.settingsForm.getRawValue()).toEqual({
      firstName: 'Ada',
      lastName: 'Lovelace',
    });
  });
});
