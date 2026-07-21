import { Page, expect } from '@playwright/test';
import { createPasswordlessAccount } from './admin';
import { E2eAccount } from './classes/e2e-account';

export type { E2eAccount } from './classes/e2e-account';

export function generateE2eAccount(prefix: string): E2eAccount {
  const unique = `${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
  return {
    email: `e2e-${prefix}-${unique}@amdash-e2e.test`,
    password: 'E2ePlaywright!1',
  };
}

// The login page is email-first: submitting the email decides server-side
// whether to show a single-password sign-in screen (an existing account) or
// a set-your-password screen (no account yet, or an admin-created one with
// no password) — see signUpAndOnboard below for that second path.
export async function signIn(page: Page, account: E2eAccount) {
  await page.goto('/login');
  await page.getByLabel('Email').fill(account.email);
  await page.getByRole('button', { name: 'Continue' }).click();
  await page.getByRole('button', { name: 'Sign In' }).waitFor();
  await page.getByLabel('Password', { exact: true }).fill(account.password);
  await page.getByRole('button', { name: 'Sign In' }).click();
}

export async function logOut(page: Page) {
  await page.getByRole('button', { name: 'Log out' }).click();
}

// Creates a brand-new throwaway account and completes the name-onboarding
// step. Every test gets its own account so tests stay independent and can
// run in parallel. Accounts are admin-created only — the login page has no
// self-registration path — so this first creates a passwordless account via
// the Admin SDK (support/admin.ts), then drives the same "set your
// password" flow a real invited user would use on first login.
export async function signUpAndOnboard(
  page: Page,
  prefix: string,
  name: { firstName: string; lastName: string } = { firstName: 'E2E', lastName: 'Tester' },
): Promise<E2eAccount> {
  const account = generateE2eAccount(prefix);

  await createPasswordlessAccount(account.email);

  await page.goto('/login');
  await page.getByLabel('Email').fill(account.email);
  await page.getByRole('button', { name: 'Continue' }).click();

  // The account exists (just created above) but has no password yet, so
  // this lands on the set-your-password step.
  await page.getByRole('button', { name: 'Set Password' }).waitFor();
  await page.getByLabel('Password', { exact: true }).fill(account.password);
  await page.getByLabel('Confirm Password').fill(account.password);
  await page.getByRole('button', { name: 'Set Password' }).click();

  // Setting the password itself triggers an in-flight navigation to '/'
  // that resolves (through authGuard, then adminGuard) only once the
  // profile has loaded — clicking the avatar link before that settles races
  // it and can get superseded by it, landing somewhere unexpected. Wait for
  // the app to navigate away from /login on its own first.
  await page.waitForURL((url) => !url.pathname.endsWith('/login'), { timeout: 15000 });

  // There's no forced redirect to /user-settings — the nav bar's avatar
  // circle is always clickable (even before a name is set) and is the only
  // way there.
  await page.getByRole('link', { name: 'Account settings' }).click();
  await expect(page).toHaveURL(/\/user-settings$/);
  await page.getByLabel('First Name').fill(name.firstName);
  await page.getByLabel('Last Name').fill(name.lastName);
  await page.getByRole('button', { name: 'Continue' }).click();

  return account;
}
