import { test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, generateE2eAccount, signIn } from './support/auth';
import { createAccountWithPassword, deleteHospitalByName } from './support/admin';

// Every test below signs in with this one account (via signIn(), below)
// rather than creating and deleting its own — this file only ever creates
// one throwaway admin. Serial mode is required, not just tidy: with this
// suite's fullyParallel: true, tests in one file can otherwise be spread
// across multiple worker processes, and beforeAll/afterAll run once per
// worker — forcing serial execution is what actually guarantees exactly one
// account gets created and deleted, not up to one per test.
test.describe.configure({ mode: 'serial' });

let sharedAdmin: E2eAccount;

test.beforeAll(async () => {
  sharedAdmin = generateE2eAccount('hospital-admin');
  await createAccountWithPassword(sharedAdmin.email, sharedAdmin.password, 'admin');
});

test.afterAll(async () => {
  await deleteAccount(sharedAdmin);
});

// The test below also deletes its hospital via the UI's own delete button —
// but that only runs if every earlier step succeeds. This afterEach is an
// idempotent safety net (deleteHospitalByName is a no-op if the UI delete
// already ran) so a mid-test failure can't leave a `hospitals` doc behind.
let createdHospitalName: string | undefined;

test.afterEach(async () => {
  if (createdHospitalName) {
    await deleteHospitalByName(createdHospitalName);
    createdHospitalName = undefined;
  }
});

test.describe('hospital management', () => {
  test('an admin can add a hospital and delete it again', async ({ page }) => {
    await signIn(page, sharedAdmin);
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible();

    // Drive the hamburger menu itself rather than page.goto('/hospitals')
    // directly, so this also exercises the nav-bar link, not just the route.
    await page.getByRole('button', { name: 'Open navigation menu' }).click();
    await page.getByRole('menuitem', { name: 'Hospitals' }).click();
    await expect(page.getByRole('heading', { name: 'Hospital Management' })).toBeVisible();

    // createHospital geocodes this address server-side (see
    // functions/src/index.ts) — a real, well-known address so that call
    // reliably succeeds against the actual Geocoding API.
    const name = `E2E Test Hospital ${Date.now()}`;
    const address = '100 Queen St W, Toronto, ON';
    createdHospitalName = name;

    await page.getByLabel('Name').fill(name);
    await page.getByLabel('Address').fill(address);
    await page.getByRole('button', { name: 'Add Hospital' }).click();

    await expect(page.locator('.form-message--success')).toContainText(name);
    const row = page.locator('.hospitals-table tbody tr', { hasText: name });
    await expect(row).toBeVisible();
    await expect(row).toContainText(address);

    await row.getByRole('button', { name: `Delete ${name}` }).click();
    await expect(row).toHaveCount(0);
  });

  test('adding a hospital with empty fields does not submit', async ({ page }) => {
    await signIn(page, sharedAdmin);
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible();
    await page.goto('/hospitals');
    await expect(page.getByRole('heading', { name: 'Hospital Management' })).toBeVisible();

    // hospitals() (hospital-management.component.ts) starts as an empty
    // signal and only fills in once the Firestore listener's first snapshot
    // arrives — reading .count() before that lands races the real data and
    // reads 0 regardless of how many hospitals actually exist. Waiting for
    // the first row to render (this dev project always has real, seeded
    // hospitals) guarantees the snapshot has landed before the count below
    // is captured.
    await expect(page.locator('.hospitals-table tbody tr').first()).toBeVisible();
    const rowCountBefore = await page.locator('.hospitals-table tbody tr').count();

    await page.getByRole('button', { name: 'Add Hospital' }).click();

    // onCreateHospital() returns early on an invalid form (see
    // hospital-management.component.ts) — no success message, no new row.
    await expect(page.locator('.form-message--success')).toHaveCount(0);
    await expect(page.locator('.hospitals-table tbody tr')).toHaveCount(rowCountBefore);
  });

  test('an admin can turn on retain-all-data, and it persists across a reload', async ({ page }) => {
    await signIn(page, sharedAdmin);
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible();

    // Drive the hamburger menu itself rather than page.goto('/settings')
    // directly, so this also exercises the nav-bar link, not just the route.
    await page.getByRole('button', { name: 'Open navigation menu' }).click();
    await page.getByRole('menuitem', { name: 'Settings' }).click();
    await expect(page.getByRole('heading', { name: 'Organization Settings' })).toBeVisible();

    // mat-slide-toggle renders with role="switch", same as the EMS app's
    // "Live-track this patient" toggle.
    const toggle = page.getByRole('switch', { name: 'Retain all patient data indefinitely' });
    // test-org (every e2e fixture's org) never has retainAllData set
    // beforehand — starts unchecked.
    await expect(toggle).toHaveAttribute('aria-checked', 'false', { timeout: 15000 });

    await toggle.click();
    await expect(toggle).toHaveAttribute('aria-checked', 'true');
    await expect(page.locator('.form-message--error')).toHaveCount(0);

    // Reloading re-reads organizations/{orgId} fresh from Firestore (see
    // organization-settings.component.ts's onSnapshot) rather than any
    // client-side cached/optimistic state — this is what actually proves
    // setOrganizationRetention's write landed, not just that the toggle's
    // own local UI state flipped.
    await page.reload();
    await expect(page.getByRole('heading', { name: 'Organization Settings' })).toBeVisible();
    await expect(toggle).toHaveAttribute('aria-checked', 'true', { timeout: 15000 });

    // Leave test-org back the way every other e2e test that relies on the
    // default 48h cleanup expects to find it.
    await toggle.click();
    await expect(toggle).toHaveAttribute('aria-checked', 'false');
  });
});
