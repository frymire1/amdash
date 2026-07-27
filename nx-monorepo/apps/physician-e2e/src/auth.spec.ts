import { test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, generateE2eAccount, logOut, signUpAndOnboard } from './support/auth';
import { createAccountWithPassword, createPasswordlessAccount, grantRole } from './support/admin';

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

  // OfflineBannerComponent is rendered in app.html outside <router-outlet>,
  // wired into this app's own app.ts independently of the other two apps —
  // needs its own check that this app's wiring is actually correct, not just
  // that the shared component works somewhere. No account needed: it's
  // visible on every route, authenticated or not. context.setOffline()
  // fires the browser's real online/offline events, unlike simulating a
  // stuck Firestore write (see with-timeout.ts's own comment) — this is
  // exactly what that API is for.
  test('shows an offline banner when the connection drops, and hides it once it returns', async ({
    page,
    context,
  }) => {
    await page.goto('/login');
    await expect(page.locator('.offline-banner')).toHaveCount(0);

    await context.setOffline(true);
    await expect(page.locator('.offline-banner')).toBeVisible();

    await context.setOffline(false);
    await expect(page.locator('.offline-banner')).toHaveCount(0);
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
  // Write WebChannel — a long-lived, multiplexed connection the client keeps
  // open and reuses across writes once established. Reaching /work-location
  // through the normal onboarding UI (Set Password, then saveProfile via
  // user-settings) would open that channel on saveProfile's own write, well
  // before this test ever registers its interception — meaning this write
  // could go out over that already-open connection instead of a fresh
  // request the interception would catch, and silently succeed anyway. Using
  // createAccountWithPassword to skip straight to a real Sign In means this
  // is the very first Firestore write of the whole browser session, so
  // there's no such connection yet to reuse.
  //
  // Also: Firestore never actually rejects a write blocked this way — it
  // retries indefinitely instead of erroring — so this doesn't hit an
  // application-level error at all. It hits with-timeout.ts's timeout after
  // 15s, which is what actually produces the error message here. Confirmed
  // by watching this exact test hang on "Saving…" for 45+ seconds with no
  // error before that timeout existed.
  test('shows an error if saving the work location fails, without navigating away', async ({ page }) => {
    test.setTimeout(60000);

    const account = generateE2eAccount('worklocation-fail');
    createdAccount = account;
    await createAccountWithPassword(account.email, account.password, 'physician');

    await page.goto('/login');
    await page.getByLabel('Email').fill(account.email);
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Sign In' }).waitFor();
    await page.getByLabel('Password', { exact: true }).fill(account.password);
    await page.getByRole('button', { name: 'Sign In' }).click();
    await expect(page).toHaveURL(/\/work-location$/, { timeout: 15000 });

    await page.getByRole('combobox', { name: 'Hospital' }).fill('General Hospital');
    await page.getByRole('option', { name: 'General Hospital', exact: true }).click();

    await page.route('**/Write/channel**', (route) => route.abort('failed'));

    await page.getByRole('button', { name: 'Continue' }).click();

    await expect(page.locator('.work-location-card__button-spinner')).toBeVisible();
    await expect(page.locator('.work-location-card__error')).toHaveText(
      'This is taking longer than expected. Check your connection and try again.',
      { timeout: 20000 },
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
