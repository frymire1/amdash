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

    // Real signInWithPassword round trip, so the spinner is reliably
    // observable without needing to force a delay — it's only replaced by
    // the error message once Firebase actually rejects the credentials.
    await expect(page.locator('.login-card__button-spinner')).toBeVisible();
    await expect(page.locator('.login-card__error')).toHaveText('Invalid email or password.');
  });

  // setInitialPassword (functions/src/index.ts) has no natural way to fail
  // from valid input the way a wrong password does above, so this forces it
  // via network interception — the only way to exercise
  // login.component.ts's onSubmitSetPassword() catch block at all. Needs a
  // real admin-created (passwordless) account to even reach the set-password
  // step — an unactivated email lands on not-activated instead.
  test('shows an error if the set-password request fails, without navigating away', async ({ page }) => {
    const account = generateE2eAccount('setpw-fail');
    createdAccount = account;
    await createPasswordlessAccount(account.email);

    await page.goto('/login');
    await page.getByLabel('Email').fill(account.email);
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Set Password' }).waitFor();

    await page.route('**/setInitialPassword**', (route) => route.abort('failed'));

    await page.getByLabel('Password', { exact: true }).fill(account.password);
    await page.getByLabel('Confirm Password').fill(account.password);
    await page.getByRole('button', { name: 'Set Password' }).click();

    await expect(page.locator('.login-card__button-spinner')).toBeVisible();
    await expect(page.locator('.login-card__error')).toHaveText('Could not set your password. Please try again.');
    await expect(page).toHaveURL(/\/login$/);

    await page.unroute('**/setInitialPassword**');
  });

  // saveProfile() (user-settings.component.ts) goes through Firestore's
  // Write WebChannel — a multiplexed, long-polling connection, not a
  // discrete per-call HTTPS request — so this aborts the whole channel
  // rather than one specific call. Narrowly scoped to this one click: at
  // this point in the test, this account's own setDoc is the only thing
  // using it.
  test('shows an error if saving the profile fails, without navigating away', async ({ page }) => {
    const account = generateE2eAccount('settings-fail');
    createdAccount = account;
    await createPasswordlessAccount(account.email);

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
    await page.getByLabel('Last Name').fill('SettingsFail');

    await page.route('**/Write/channel**', (route) => route.abort('failed'));

    await page.getByRole('button', { name: 'Continue' }).click();

    await expect(page.locator('.user-settings-card__button-spinner')).toBeVisible();
    await expect(page.locator('.user-settings-card__error')).toHaveText('Failed to save your details. Please try again.');
    await expect(page).toHaveURL(/\/user-settings$/);

    await page.unroute('**/Write/channel**');
  });

  // A real user's actual journey: sign up once (Set Password, then save
  // profile), then log back in later. Covers the Set Password, user-settings
  // Continue, and Sign In buttons' in-flight spinners together, each
  // immediately followed by the navigation it leads to on success.
  test('shows a spinner on each submit during sign-up and a later sign-in, then navigates every time', async ({
    page,
  }) => {
    const account = generateE2eAccount('onboarding-spinner');
    createdAccount = account;
    await createPasswordlessAccount(account.email);

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
    await page.getByLabel('Last Name').fill('Onboarding');

    // Must land before the Continue click below, since that's what
    // navigates into the role-guarded app routes.
    await grantRole(account.email, 'ems');

    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.locator('.user-settings-card__button-spinner')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'EMS Dashboard' })).toBeVisible({ timeout: 15000 });

    await logOut(page);

    await page.getByLabel('Email').fill(account.email);
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Sign In' }).waitFor();
    await page.getByLabel('Password', { exact: true }).fill(account.password);

    await page.getByRole('button', { name: 'Sign In' }).click();
    await expect(page.locator('.login-card__button-spinner')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'EMS Dashboard' })).toBeVisible({ timeout: 15000 });
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
