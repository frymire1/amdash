import { test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, signIn, signUpAndOnboard } from './support/auth';

let createdAccount: E2eAccount | undefined;

test.afterEach(async ({ request }) => {
  if (!createdAccount) {
    return;
  }
  await deleteAccount(request, createdAccount);
  createdAccount = undefined;
});

test.describe('physician auth', () => {
  test('redirects an unauthenticated visitor to the login page', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveURL(/\/login$/);
  });

  test('shows an error for invalid credentials', async ({ page }) => {
    await signIn(page, { email: 'no-such-account@amdash-e2e.test', password: 'WrongPassword1!' });
    await expect(page.locator('.login-card__error')).toHaveText('Invalid email or password.');
  });

  test('a freshly signed-up account completes onboarding and reaches the patient list', async ({ page }) => {
    createdAccount = await signUpAndOnboard(page, 'physician', undefined, { role: 'physician' });

    await expect(page).toHaveURL(/\/physician$/);
    await expect(page.getByRole('heading', { name: 'Patient List' })).toBeVisible();
    await expect(page.locator('.user-avatar--initials')).toBeVisible();
  });
});
