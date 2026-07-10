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

export async function signIn(page: Page, account: E2eAccount, options?: { origin?: string }) {
  const origin = options?.origin ?? '';
  await page.goto(`${origin}/login`);
  await page.getByLabel('Email').fill(account.email);
  await page.getByLabel('Password').fill(account.password);
  await page.getByRole('button', { name: 'Sign In' }).click();
}

export async function logOut(page: Page) {
  await page.getByRole('button', { name: 'Log out' }).click();
}

// Creates a brand-new throwaway account via the shared login component's
// sign-up mode and completes the mandatory name-onboarding step. Every test
// gets its own account so tests stay independent and can run in parallel.
// `options.origin` lets a single page drive a *different* app (e.g. EMS on
// its own port) while it's mainly navigating a different one via `baseURL`.
export async function signUpAndOnboard(
  page: Page,
  prefix: string,
  name: { firstName: string; lastName: string } = { firstName: 'E2E', lastName: 'Tester' },
  options?: { origin?: string },
): Promise<E2eAccount> {
  const account = generateE2eAccount(prefix);
  const origin = options?.origin ?? '';

  await page.goto(`${origin}/login`);
  await page.getByRole('button', { name: "Don't have an account? Create one" }).click();
  await page.getByLabel('Email').fill(account.email);
  await page.getByLabel('Password').fill(account.password);
  await page.getByRole('button', { name: 'Create Account' }).click();

  await expect(page).toHaveURL(new RegExp(`${origin.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/user-settings$`));
  await page.getByLabel('First Name').fill(name.firstName);
  await page.getByLabel('Last Name').fill(name.lastName);
  await page.getByRole('button', { name: 'Continue' }).click();

  return account;
}
