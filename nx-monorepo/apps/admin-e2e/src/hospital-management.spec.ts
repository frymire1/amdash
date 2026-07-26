import { test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, signUpAndOnboard } from './support/auth';
import { deleteHospitalByName } from './support/admin';

// The test below also deletes its hospital via the UI's own delete button —
// but that only runs if every earlier step succeeds. This afterEach is an
// idempotent safety net (deleteHospitalByName is a no-op if the UI delete
// already ran) so a mid-test failure can't leave a `hospitals` doc behind.
let createdAdmin: E2eAccount | undefined;
let createdHospitalName: string | undefined;

test.afterEach(async () => {
  if (createdHospitalName) {
    await deleteHospitalByName(createdHospitalName);
    createdHospitalName = undefined;
  }
  if (createdAdmin) {
    await deleteAccount(createdAdmin);
    createdAdmin = undefined;
  }
});

test.describe('hospital management', () => {
  test('an admin can add a hospital and delete it again', async ({ page }) => {
    // The admin account driving this test is itself just another throwaway
    // e2e account — see role-assignment.spec.ts for why granting 'admin' via
    // the Admin SDK here is fine even though the app's own UI has no
    // self-granting path.
    await signUpAndOnboard(page, 'hospital-admin', undefined, {
      role: 'admin',
      onAccountCreated: (account) => (createdAdmin = account),
    });
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
    await signUpAndOnboard(page, 'hospital-admin-empty', undefined, {
      role: 'admin',
      onAccountCreated: (account) => (createdAdmin = account),
    });
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible();
    await page.goto('/hospitals');
    await expect(page.getByRole('heading', { name: 'Hospital Management' })).toBeVisible();

    const rowCountBefore = await page.locator('.hospitals-table tbody tr').count();

    await page.getByRole('button', { name: 'Add Hospital' }).click();

    // onCreateHospital() returns early on an invalid form (see
    // hospital-management.component.ts) — no success message, no new row.
    await expect(page.locator('.form-message--success')).toHaveCount(0);
    await expect(page.locator('.hospitals-table tbody tr')).toHaveCount(rowCountBefore);
  });
});
