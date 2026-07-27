import { test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, generateE2eAccount, logOut, signUpAndOnboard } from './support/auth';
import { createPasswordlessAccount, grantRole } from './support/admin';

let createdAccount: E2eAccount | undefined;

test.afterEach(async () => {
  if (!createdAccount) {
    return;
  }
  await deleteAccount(createdAccount);
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

    // Real signInWithPassword round trip, so the spinner is reliably
    // observable without needing to force a delay — it's only replaced by
    // the error message once Firebase actually rejects the credentials.
    await expect(page.locator('.login-card__button-spinner')).toBeVisible();
    await expect(page.locator('.login-card__error')).toHaveText('Invalid email or password.');
  });

  // saveWorkLocation() (work-location.component.ts) goes through Firestore's
  // Write WebChannel — a multiplexed, long-polling connection, not a
  // discrete per-call HTTPS request — so this aborts the whole channel
  // rather than one specific call. Narrowly scoped to this one click: at
  // this point in the test, this account's own setDoc is the only thing
  // using it.
  test('shows an error if saving the work location fails, without navigating away', async ({ page }) => {
    const account = generateE2eAccount('worklocation-fail');
    createdAccount = account;
    await createPasswordlessAccount(account.email);
    await grantRole(account.email, 'physician');

    await page.goto('/login');
    await page.getByLabel('Email').fill(account.email);
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Set Password' }).waitFor();
    await page.getByLabel('Password', { exact: true }).fill(account.password);
    await page.getByLabel('Confirm Password').fill(account.password);
    await page.getByRole('button', { name: 'Set Password' }).click();
    await page.waitForURL((url) => !url.pathname.endsWith('/login'), { timeout: 15000 });

    await page.getByRole('link', { name: 'Account settings' }).click();
    await expect(page).toHaveURL(/\/user-settings$/);
    await page.getByLabel('First Name').fill('E2E');
    await page.getByLabel('Last Name').fill('WorkLocationFail');
    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page).toHaveURL(/\/work-location$/);

    await page.getByRole('combobox', { name: 'Hospital' }).fill('General Hospital');
    await page.getByRole('option', { name: 'General Hospital', exact: true }).click();

    await page.route('**/Write/channel**', (route) => route.abort('failed'));

    await page.getByRole('button', { name: 'Continue' }).click();

    await expect(page.locator('.work-location-card__button-spinner')).toBeVisible();
    await expect(page.locator('.work-location-card__error')).toHaveText(
      'Failed to save your work location. Please try again.',
    );
    await expect(page).toHaveURL(/\/work-location$/);

    await page.unroute('**/Write/channel**');
  });

  test('an unknown email shows a not-activated error instead of self-registering', async ({ page }) => {
    const email = 'no-such-account-' + Date.now() + '@amdash-e2e.test';
    await page.goto('/login');
    await page.getByLabel('Email').fill(email);
    await page.getByRole('button', { name: 'Continue' }).click();

    await expect(page.getByText(`Your email, ${email}, has not been activated by your admin.`)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Use a different email' })).toBeVisible();
  });

  // A real user's actual journey: sign up once (Set Password, save profile,
  // pick a work location), then log back in later. Covers the Set Password,
  // user-settings Continue, work-location Continue, and Sign In buttons'
  // in-flight spinners together, each immediately followed by the
  // navigation it leads to on success.
  test('shows a spinner on each submit while completing onboarding and a later sign-in, then navigates every time', async ({
    page,
  }) => {
    const account = generateE2eAccount('physician');
    createdAccount = account;
    await createPasswordlessAccount(account.email);
    await grantRole(account.email, 'physician');

    await page.goto('/login');
    await page.getByLabel('Email').fill(account.email);
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Set Password' }).waitFor();
    await page.getByLabel('Password', { exact: true }).fill(account.password);
    await page.getByLabel('Confirm Password').fill(account.password);

    await page.getByRole('button', { name: 'Set Password' }).click();
    await expect(page.locator('.login-card__button-spinner')).toBeVisible();
    await expect(page).not.toHaveURL(/\/login$/, { timeout: 15000 });

    await page.getByRole('link', { name: 'Account settings' }).click();
    await expect(page).toHaveURL(/\/user-settings$/);
    await page.getByLabel('First Name').fill('E2E');
    await page.getByLabel('Last Name').fill('Physician');

    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.locator('.user-settings-card__button-spinner')).toBeVisible();
    await expect(page).toHaveURL(/\/work-location$/, { timeout: 15000 });

    await page.getByRole('combobox', { name: 'Hospital' }).fill('General Hospital');
    await page.getByRole('option', { name: 'General Hospital', exact: true }).click();

    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.locator('.work-location-card__button-spinner')).toBeVisible();
    await expect(page).toHaveURL(/\/physician$/, { timeout: 15000 });
    await expect(page.getByRole('heading', { name: 'Patient List' })).toBeVisible();
    await expect(page.locator('.user-avatar--initials')).toBeVisible();

    await logOut(page);

    await page.getByLabel('Email').fill(account.email);
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Sign In' }).waitFor();
    await page.getByLabel('Password', { exact: true }).fill(account.password);

    await page.getByRole('button', { name: 'Sign In' }).click();
    await expect(page.locator('.login-card__button-spinner')).toBeVisible();
    await expect(page).toHaveURL(/\/physician$/, { timeout: 15000 });
  });

  // An EMS-only account hitting the physician app should land on
  // access-denied with a link to the app its actual role does grant it —
  // not a dead end.
  test('access-denied links to the app matching the account\'s actual role', async ({ page }) => {
    createdAccount = await signUpAndOnboard(page, 'ems-on-physician', undefined, {
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
