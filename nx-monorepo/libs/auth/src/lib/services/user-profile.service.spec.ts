import { TestBed } from '@angular/core/testing';

import { UserProfileService } from './user-profile.service';

describe('UserProfileService', () => {
  let service: UserProfileService;

  beforeEach(() => {
    TestBed.configureTestingModule({});
    service = TestBed.inject(UserProfileService);
  });

  it('should create', () => {
    expect(service).toBeTruthy();
  });

  it('has no initials before a profile is loaded', () => {
    expect(service.initials()).toBe('');
  });
});
