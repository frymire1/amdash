import { test, expect } from '@playwright/test';
import { signIn } from './support/auth';
import { deleteHospitalByName } from './support/admin';

// Needs a real, pre-existing admin account (role: 'admin' set by hand in the
// Firestore console) since nothing can self-grant that role anymore — same
// constraint as role-assignment.spec.ts.
const ADMIN_EMAIL = process.env['E2E_ADMIN_EMAIL'];
const ADMIN_PASSWORD = process.env['E2E_ADMIN_PASSWORD'];

// The test below also deletes its hospital via the UI's own delete button —
// but that only runs if every earlier step succeeds. This afterEach is an
// idempotent safety net (deleteHospitalByName is a no-op if the UI delete
// already ran) so a mid-test failure can't leave a `hospitals` doc behind.
let createdHospitalName: string | undefined;

test.afterEach(async () => {
  if (!createdHospitalName) {
    return;
  }
  await deleteHospitalByName(createdHospitalName);
  createdHospitalName = undefined;
});

test.describe('hospital management', () => {
  test.skip(
    !ADMIN_EMAIL || !ADMIN_PASSWORD,
    'Set E2E_ADMIN_EMAIL / E2E_ADMIN_PASSWORD to an existing admin account to run these tests.',
  );

  test('an admin can add a hospital and delete it again', async ({ page }) => {
    await signIn(page, { email: ADMIN_EMAIL as string, password: ADMIN_PASSWORD as string });
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
    await signIn(page, { email: ADMIN_EMAIL as string, password: ADMIN_PASSWORD as string });
    // signIn() doesn't wait for the post-sign-in redirect to settle — only
    // for the click. Navigating straight to /hospitals can race that
    // redirect and land back on /login. Wait for the app's own landing page
    // first, same as the test above.
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
