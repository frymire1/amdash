import { test, expect } from '@playwright/test';
import { signIn, signUpAndOnboard } from './support/auth';

test.describe('admin auth', () => {
  test('redirects an unauthenticated visitor to the login page', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveURL(/\/login$/);
  });

  test('shows an error for invalid credentials', async ({ page }) => {
    await signIn(page, { email: 'no-such-account@amdash-e2e.test', password: 'WrongPassword1!' });
    await expect(page.locator('.login-card__error')).toHaveText('Invalid email or password.');
  });

  test('a non-admin account is redirected to access-denied after onboarding', async ({ page }) => {
    await signUpAndOnboard(page, 'admin-nonadmin');

    await expect(page).toHaveURL(/\/access-denied$/);
    await expect(page.getByRole('heading', { name: 'Access denied' })).toBeVisible();
  });
});
