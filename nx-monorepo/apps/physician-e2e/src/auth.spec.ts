import { test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, logOut, signUpAndOnboard } from './support/auth';

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

  // An email with no account at all doesn't error — the login page is
  // email-first and lets an unknown email self-register (see the sign-up
  // test below). Testing "invalid credentials" therefore needs a *real*
  // account and a wrong password on its sign-in step.
  test('shows an error for invalid credentials', async ({ page }) => {
    createdAccount = await signUpAndOnboard(page, 'invalid-creds');
    await logOut(page);

    await page.goto('/login');
    await page.getByLabel('Email').fill(createdAccount.email);
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Sign In' }).waitFor();
    await page.getByLabel('Password', { exact: true }).fill('WrongPassword1!');
    await page.getByRole('button', { name: 'Sign In' }).click();

    await expect(page.locator('.login-card__error')).toHaveText('Invalid email or password.');
  });

  test('an unknown email routes to self-registration instead of an error', async ({ page }) => {
    await page.goto('/login');
    await page.getByLabel('Email').fill('no-such-account-' + Date.now() + '@amdash-e2e.test');
    await page.getByRole('button', { name: 'Continue' }).click();

    await expect(page.getByText('Create your account')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Set Password' })).toBeVisible();
  });

  test('a freshly signed-up account completes onboarding and reaches the patient list', async ({ page }) => {
    createdAccount = await signUpAndOnboard(page, 'physician', undefined, {
      role: 'physician',
      hospital: 'General Hospital',
    });

    await expect(page).toHaveURL(/\/physician$/);
    await expect(page.getByRole('heading', { name: 'Patient List' })).toBeVisible();
    await expect(page.locator('.user-avatar--initials')).toBeVisible();
  });
});
