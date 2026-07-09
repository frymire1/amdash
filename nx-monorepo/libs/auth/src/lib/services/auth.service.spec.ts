import { TestBed } from '@angular/core/testing';

import { AuthService } from './auth.service';

describe('AuthService', () => {
  let service: AuthService;

  beforeEach(() => {
    TestBed.configureTestingModule({});
    service = TestBed.inject(AuthService);
  });

  it('should create', () => {
    expect(service).toBeTruthy();
  });

  it('is not authenticated before the initial auth state resolves', () => {
    expect(service.isAuthenticated()).toBe(false);
  });
});
