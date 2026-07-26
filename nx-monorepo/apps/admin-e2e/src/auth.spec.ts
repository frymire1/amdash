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

test.describe('admin auth', () => {
  test('redirects an unauthenticated visitor to the login page', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveURL(/\/login$/);
  });

  // An email with no account at all doesn't error via self-registration —
  // the login page has no such path — it lands on the not-activated step
  // instead (see the test below). Testing "invalid credentials" therefore
  // needs a *real* account and a wrong password on its sign-in step.
  test('shows an error for invalid credentials', async ({ page }) => {
    createdAccount = await signUpAndOnboard(page, 'invalid-creds', undefined, {
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

  // Same shared LoginComponent as physician/ems — verifies the not-activated
  // step here too rather than assuming it, since this is the one behavior
  // that used to differ across apps before self-registration was removed.
  test('an unknown email shows a not-activated error instead of self-registering', async ({ page }) => {
    const email = 'no-such-account-' + Date.now() + '@amdash-e2e.test';
    await page.goto('/login');
    await page.getByLabel('Email').fill(email);
    await page.getByRole('button', { name: 'Continue' }).click();

    await expect(page.getByText(`Your email, ${email}, has not been activated by your admin.`)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Use a different email' })).toBeVisible();
  });

  test('a non-admin account is redirected to access-denied after onboarding', async ({ page }) => {
    createdAccount = await signUpAndOnboard(page, 'admin-nonadmin', undefined, {
      onAccountCreated: (account) => (createdAccount = account),
    });

    await expect(page).toHaveURL(/\/access-denied$/);
    await expect(page.getByRole('heading', { name: 'Access denied' })).toBeVisible();
  });

  // An EMS-only account hitting the admin app should land on access-denied
  // with a link to the app its actual role does grant it — not a dead end.
  test("access-denied links to the app matching the account's actual role", async ({ page }) => {
    createdAccount = await signUpAndOnboard(page, 'ems-on-admin', undefined, {
      role: 'ems',
      onAccountCreated: (account) => (createdAccount = account),
    });

    await expect(page).toHaveURL(/\/access-denied$/);
    await expect(page.getByRole('heading', { name: 'Access denied' })).toBeVisible();

    const emsLink = page.getByRole('link', { name: 'EMS app' });
    await expect(emsLink).toBeVisible();
    await expect(emsLink).toHaveAttribute('href', 'https://amdash-ems-dev.web.app');
    await expect(page.getByRole('link', { name: 'Physician app' })).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'Admin app' })).toHaveCount(0);
  });
});
