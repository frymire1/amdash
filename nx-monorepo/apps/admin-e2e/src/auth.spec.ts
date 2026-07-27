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

test.describe('admin auth', () => {
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

    // Real signInWithPassword round trip, so the spinner is reliably
    // observable without needing to force a delay — it's only replaced by
    // the error message once Firebase actually rejects the credentials.
    await expect(page.locator('.login-card__button-spinner')).toBeVisible();
    await expect(page.locator('.login-card__error')).toHaveText('Invalid email or password.');
  });

  // A real user's actual journey: sign up once (Set Password, then save
  // profile), then log back in later. Covers the Set Password, user-settings
  // Continue, and Sign In buttons' in-flight spinners together, each
  // immediately followed by the navigation it leads to on success. Grants
  // itself a throwaway 'admin' role via the Admin SDK the same way
  // role-assignment.spec.ts's fixture account does — see that file for why
  // that's fine even though the app's own UI has no self-granting path.
  test('shows a spinner on each submit during sign-up and a later sign-in, then navigates every time', async ({
    page,
  }) => {
    const account = generateE2eAccount('onboarding-spinner');
    createdAccount = account;
    await createPasswordlessAccount(account.email);
    await grantRole(account.email, 'admin');

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

    await page.getByRole('button', { name: 'Continue' }).click();
    await expect(page.locator('.user-settings-card__button-spinner')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible({ timeout: 15000 });

    await logOut(page);

    await page.getByLabel('Email').fill(account.email);
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByRole('button', { name: 'Sign In' }).waitFor();
    await page.getByLabel('Password', { exact: true }).fill(account.password);

    await page.getByRole('button', { name: 'Sign In' }).click();
    await expect(page.locator('.login-card__button-spinner')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible({ timeout: 15000 });
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
