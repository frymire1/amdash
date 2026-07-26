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

  test('an unknown email shows a not-activated error instead of self-registering', async ({ page }) => {
    const email = 'no-such-account-' + Date.now() + '@amdash-e2e.test';
    await page.goto('/login');
    await page.getByLabel('Email').fill(email);
    await page.getByRole('button', { name: 'Continue' }).click();

    await expect(page.getByText(`Your email, ${email}, has not been activated by your admin.`)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Use a different email' })).toBeVisible();
  });

  // A physician-only account hitting the EMS app should land on
  // access-denied with a link to the app its actual role does grant it —
  // not a dead end.
  test("access-denied links to the app matching the account's actual role", async ({ page }) => {
    createdAccount = await signUpAndOnboard(page, 'physician-on-ems', undefined, {
      role: 'physician',
      onAccountCreated: (account) => (createdAccount = account),
    });

    await expect(page).toHaveURL(/\/access-denied$/);
    await expect(page.getByRole('heading', { name: 'Access denied' })).toBeVisible();

    const physicianLink = page.getByRole('link', { name: 'Physician app' });
    await expect(physicianLink).toBeVisible();
    await expect(physicianLink).toHaveAttribute('href', 'https://amdash-physician-dev.web.app');
    await expect(page.getByRole('link', { name: 'EMS app' })).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'Admin app' })).toHaveCount(0);
  });
});
