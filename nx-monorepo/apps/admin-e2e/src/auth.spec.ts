import { test, expect } from '@playwright/test';
import { logOut, signUpAndOnboard } from './support/auth';

test.describe('admin auth', () => {
  test('redirects an unauthenticated visitor to the login page', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveURL(/\/login$/);
  });

  // An email with no account at all doesn't error — the login page is
  // email-first and lets an unknown email self-register. Testing "invalid
  // credentials" therefore needs a *real* account and a wrong password on
  // its sign-in step.
  test('shows an error for invalid credentials', async ({ page }) => {
    const account = await signUpAndOnboard(page, 'invalid-creds');
    await logOut(page);

    await page.goto('/login');
    await page.getByLabel('Email').fill(account.email);
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Sign In' }).waitFor();
    await page.getByLabel('Password', { exact: true }).fill('WrongPassword1!');
    await page.getByRole('button', { name: 'Sign In' }).click();

    await expect(page.locator('.login-card__error')).toHaveText('Invalid email or password.');
  });

  test('a non-admin account is redirected to access-denied after onboarding', async ({ page }) => {
    await signUpAndOnboard(page, 'admin-nonadmin');

    await expect(page).toHaveURL(/\/access-denied$/);
    await expect(page.getByRole('heading', { name: 'Access denied' })).toBeVisible();
  });
});
