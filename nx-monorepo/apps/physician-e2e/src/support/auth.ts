import { APIRequestContext, Page, expect } from '@playwright/test';
import { UserRole, grantRole } from './admin';

export interface E2eAccount {
  email: string;
  password: string;
}

// Same public Web API key embedded in every app's firebase.ts — used for the
// REST calls below, mirroring how the app's own client SDK authenticates.
const API_KEY = 'AIzaSyDHOpM_Mi9NcMeZS8sD42olEMyN_MjVl5k';
const FIRESTORE_BASE = 'https://firestore.googleapis.com/v1/projects/amdash-dev/databases/(default)/documents';

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
// sign-up mode and completes the name-onboarding step. Every test gets its
// own account so tests stay independent and can run in parallel.
// `options.origin` lets a single page drive a *different* app (e.g. EMS on
// its own port) while it's mainly navigating a different one via `baseURL`.
// `options.role` grants a Firestore role via the Admin SDK (see
// support/admin.ts) before completing onboarding — physicianAppGuard /
// emsAppGuard / adminGuard all block access to their app for accounts with
// no role, and nothing client-side can ever set that field on its own.
// `options.hospital` additionally drives the mandatory /work-location step
// (workLocationGuard) that a physician/nurse role hits right after — pass it
// whenever role is 'physician' or 'nurse', since nothing will land past that
// guard otherwise.
export async function signUpAndOnboard(
  page: Page,
  prefix: string,
  name: { firstName: string; lastName: string } = { firstName: 'E2E', lastName: 'Tester' },
  options?: { origin?: string; role?: UserRole; hospital?: string },
): Promise<E2eAccount> {
  const account = generateE2eAccount(prefix);
  const origin = options?.origin ?? '';
  const originPattern = origin.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  await page.goto(`${origin}/login`);
  await page.getByRole('button', { name: "Don't have an account? Create one" }).click();
  await page.getByLabel('Email').fill(account.email);
  await page.getByLabel('Password').fill(account.password);
  await page.getByRole('button', { name: 'Create Account' }).click();

  // Sign-up itself triggers an in-flight navigation to '/' that resolves
  // (through authGuard, then the app's role guard) only once the profile
  // has loaded — clicking the avatar link before that settles races it and
  // can get superseded by it, landing somewhere unexpected. Wait for the
  // app to navigate away from /login on its own first.
  await page.waitForURL((url) => !url.pathname.endsWith('/login'), { timeout: 15000 });

  // There's no forced redirect to /user-settings after sign-up — the nav
  // bar's avatar circle is always clickable (even before a name is set) and
  // is the only way there now, so this drives that click rather than
  // waiting on a URL the app no longer navigates to on its own.
  await page.getByRole('link', { name: 'Account settings' }).click();
  await expect(page).toHaveURL(new RegExp(`${originPattern}/user-settings$`));

  if (options?.role) {
    // Must land before the "Continue" click below, since that's what
    // navigates into the role-guarded app routes. saveProfile() (called by
    // that click) re-reads the Firestore doc after its own write, so it
    // picks up this role regardless of exactly when it lands relative to
    // the profile service's own initial fetch.
    await grantRole(account.email, options.role);
  }

  await page.getByLabel('First Name').fill(name.firstName);
  await page.getByLabel('Last Name').fill(name.lastName);
  await page.getByRole('button', { name: 'Continue' }).click();

  if (options?.hospital) {
    await expect(page).toHaveURL(new RegExp(`${originPattern}/work-location$`));
    // getByLabel('Hospital') is ambiguous here: Material links the open
    // autocomplete panel's aria-labelledby to the same form-field label, so
    // it also resolves to the listbox. getByRole('combobox', ...) targets
    // only the input.
    await page.getByRole('combobox', { name: 'Hospital' }).fill(options.hospital);
    await page.getByRole('option', { name: options.hospital, exact: true }).click();
    await page.getByRole('button', { name: 'Continue' }).click();
  }

  return account;
}

// Deletes a throwaway e2e account entirely: its `users/{uid}` Firestore doc
// and the Firebase Auth account itself. Every test that calls
// signUpAndOnboard should call this in an `afterEach` — otherwise the
// account (and its Firestore profile doc) is left behind permanently, since
// nothing in the app itself ever deletes a user. Uses `request` rather than
// the test's `page` so it still works even if the test failed partway
// through and the page is in a broken state.
export async function deleteAccount(request: APIRequestContext, account: E2eAccount) {
  const signInResponse = await request.post(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${API_KEY}`,
    { data: { email: account.email, password: account.password, returnSecureToken: true } },
  );
  if (!signInResponse.ok()) {
    throw new Error(`deleteAccount: sign-in for ${account.email} failed (${signInResponse.status()}): ${await signInResponse.text()}`);
  }
  const { idToken, localId: uid } = await signInResponse.json();

  const docDeleteResponse = await request.delete(`${FIRESTORE_BASE}/users/${uid}`, {
    headers: { Authorization: `Bearer ${idToken}` },
  });
  if (!docDeleteResponse.ok()) {
    throw new Error(`deleteAccount: Firestore doc delete for ${uid} failed (${docDeleteResponse.status()}): ${await docDeleteResponse.text()}`);
  }

  const accountDeleteResponse = await request.post(`https://identitytoolkit.googleapis.com/v1/accounts:delete?key=${API_KEY}`, {
    data: { idToken },
  });
  if (!accountDeleteResponse.ok()) {
    throw new Error(`deleteAccount: Auth account delete for ${uid} failed (${accountDeleteResponse.status()}): ${await accountDeleteResponse.text()}`);
  }
}
