import { Page, expect } from '@playwright/test';

export interface E2eAccount {
  email: string;
  password: string;
}

export function generateE2eAccount(prefix: string): E2eAccount {
  const unique = `${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
  return {
    email: `e2e-${prefix}-${unique}@amdash-e2e.test`,
    password: 'E2ePlaywright!1',
  };
}

export async function signIn(page: Page, account: E2eAccount) {
  await page.goto('/login');
  await page.getByLabel('Email').fill(account.email);
  await page.getByLabel('Password').fill(account.password);
  await page.getByRole('button', { name: 'Sign In' }).click();
}

export async function logOut(page: Page) {
  await page.getByRole('button', { name: 'Log out' }).click();
}

// Creates a brand-new throwaway account via the shared login component's
// sign-up mode and completes the name-onboarding step. Every test gets its
// own account so tests stay independent and can run in parallel.
export async function signUpAndOnboard(
  page: Page,
  prefix: string,
  name: { firstName: string; lastName: string } = { firstName: 'E2E', lastName: 'Tester' },
): Promise<E2eAccount> {
  const account = generateE2eAccount(prefix);

  await page.goto('/login');
  await page.getByRole('button', { name: "Don't have an account? Create one" }).click();
  await page.getByLabel('Email').fill(account.email);
  await page.getByLabel('Password').fill(account.password);
  await page.getByRole('button', { name: 'Create Account' }).click();

  // Sign-up itself triggers an in-flight navigation to '/' that resolves
  // (through authGuard, then adminGuard) only once the profile has
  // loaded — clicking the avatar link before that settles races it and can
  // get superseded by it, landing somewhere unexpected. Wait for the app to
  // navigate away from /login on its own first.
  await page.waitForURL((url) => !url.pathname.endsWith('/login'), { timeout: 15000 });

  // There's no forced redirect to /user-settings after sign-up — the nav
  // bar's avatar circle is always clickable (even before a name is set) and
  // is the only way there now.
  await page.getByRole('link', { name: 'Account settings' }).click();
  await expect(page).toHaveURL(/\/user-settings$/);
  await page.getByLabel('First Name').fill(name.firstName);
  await page.getByLabel('Last Name').fill(name.lastName);
  await page.getByRole('button', { name: 'Continue' }).click();

  return account;
}
