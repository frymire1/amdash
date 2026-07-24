import { test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, logOut, signUpAndOnboard } from './support/auth';

let createdAccount: E2eAccount | undefined;

test.afterEach(async () => {
  if (!createdAccount) {
    return;
  }
  await deleteAccount(createdAccount);
  createdAccount = undefined;
});

test.describe('ems auth', () => {
  test('redirects an unauthenticated visitor to the login page', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveURL(/\/login$/);
  });

  // An email with no account at all shows a "not activated" error, not
  // "invalid credentials" — that specifically needs a *real* account and a
  // wrong password on its sign-in step, so this does a full signUpAndOnboard
  // (real Admin SDK account creation + onboarding UI) *and* a logout +
  // re-login attempt on top of it (see playwright.config.mts's `timeout` for
  // why that needs more than the Playwright default).
  test('shows an error for invalid credentials', async ({ page }) => {
    createdAccount = await signUpAndOnboard(page, 'invalid-creds', undefined, {
      role: 'ems',
      onAccountCreated: (account) => (createdAccount = account),
    });
    await logOut(page);

    await page.goto('/login');
    await page.getByLabel('Email').fill(createdAccount.email);
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Sign In' }).waitFor();
    await page.getByLabel('Password', { exact: true }).fill('WrongPassword1!');
    await page.getByRole('button', { name: 'Sign In' }).click();

    await expect(page.locator('.login-card__error')).toHaveText('Invalid email or password.');
  });
});
