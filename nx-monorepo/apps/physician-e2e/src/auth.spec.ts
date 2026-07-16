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

  // An email with no account at all shows the "not activated" error (see
  // the test below), not "invalid credentials" — that specifically needs a
  // *real* account and a wrong password on its sign-in step.
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

  test('an unknown email shows a not-activated error instead of self-registering', async ({ page }) => {
    const email = 'no-such-account-' + Date.now() + '@amdash-e2e.test';
    await page.goto('/login');
    await page.getByLabel('Email').fill(email);
    await page.getByRole('button', { name: 'Continue' }).click();

    await expect(page.getByText(`Your email, ${email}, has not been activated by your admin.`)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Use a different email' })).toBeVisible();
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

  // An EMS-only account hitting the physician app should land on
  // access-denied with a link to the app its actual role does grant it —
  // not a dead end.
  test('access-denied links to the app matching the account\'s actual role', async ({ page }) => {
    createdAccount = await signUpAndOnboard(page, 'ems-on-physician', undefined, { role: 'ems' });

    await expect(page).toHaveURL(/\/access-denied$/);
    await expect(page.getByRole('heading', { name: 'Access denied' })).toBeVisible();

    const emsLink = page.getByRole('link', { name: 'EMS app' });
    await expect(emsLink).toBeVisible();
    await expect(emsLink).toHaveAttribute('href', 'https://amdash-ems-dev.web.app');
    await expect(page.getByRole('link', { name: 'Physician app' })).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'Admin app' })).toHaveCount(0);
  });
});
