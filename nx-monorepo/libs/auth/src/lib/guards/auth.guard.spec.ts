import { TestBed } from '@angular/core/testing';
import { signal } from '@angular/core';
import { provideRouter, UrlTree } from '@angular/router';
import { firstValueFrom, isObservable } from 'rxjs';

import { authGuard, guestGuard } from './auth.guard';
import { AuthService } from '../services/auth.service';

describe('authGuard', () => {
  async function runGuard(guardFn: typeof authGuard, isAuthenticated: boolean) {
    const authServiceStub = {
      initializing: signal(false),
      isAuthenticated: () => isAuthenticated,
    };

    TestBed.configureTestingModule({
      providers: [provideRouter([]), { provide: AuthService, useValue: authServiceStub }],
    });

    const result = TestBed.runInInjectionContext(() => guardFn({} as never, {} as never));
    return isObservable(result) ? firstValueFrom(result) : result;
  }

  it('allows navigation when authenticated', async () => {
    const result = await runGuard(authGuard, true);
    expect(result).toBe(true);
  });

  it('redirects to /login when not authenticated', async () => {
    const result = await runGuard(authGuard, false);
    expect(result).toBeInstanceOf(UrlTree);
  });

  it('guestGuard allows navigation when not authenticated', async () => {
    const result = await runGuard(guestGuard, false);
    expect(result).toBe(true);
  });

  it('guestGuard redirects to / when authenticated', async () => {
    const result = await runGuard(guestGuard, true);
    expect(result).toBeInstanceOf(UrlTree);
  });
});
