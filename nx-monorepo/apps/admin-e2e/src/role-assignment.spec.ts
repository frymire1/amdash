import { test, expect } from '@playwright/test';
import { logOut, signIn, signUpAndOnboard } from './support/auth';

// This test needs a real, pre-existing admin account (role: 'admin' set by
// hand in the Firestore console) since nothing can self-grant that role
// anymore. Point it at your own admin dev account to exercise this path.
const ADMIN_EMAIL = process.env['E2E_ADMIN_EMAIL'];
const ADMIN_PASSWORD = process.env['E2E_ADMIN_PASSWORD'];

test.describe('admin role assignment', () => {
  test.skip(
    !ADMIN_EMAIL || !ADMIN_PASSWORD,
    'Set E2E_ADMIN_EMAIL / E2E_ADMIN_PASSWORD to an existing admin account to run this test.',
  );

  test('an admin can assign multiple roles to another user by email, then remove one', async ({ page }) => {
    // Create a disposable target account to assign roles to, rather than
    // mutating the admin fixture account's own roles.
    const target = await signUpAndOnboard(page, 'admin-target');
    await logOut(page);

    await signIn(page, { email: ADMIN_EMAIL as string, password: ADMIN_PASSWORD as string });
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible();

    const row = page.locator('.users-table tbody tr', { hasText: target.email });

    await page.getByLabel('User email').fill(target.email);
    await page.getByLabel('Role').click();
    await page.getByRole('option', { name: 'EMS' }).click();
    await page.getByRole('button', { name: 'Assign Role' }).click();
    await expect(page.locator('.form-message--success')).toContainText(target.email);
    await expect(row.locator('.role-badge')).toHaveCount(1);
    await expect(row.locator('.role-badge')).toContainText('ems');

    // A second, different role should add alongside the first rather than
    // replace it — this is the whole point of role now being an array.
    await page.getByLabel('User email').fill(target.email);
    await page.getByLabel('Role').click();
    await page.getByRole('option', { name: 'Nurse' }).click();
    await page.getByRole('button', { name: 'Assign Role' }).click();
    await expect(page.locator('.form-message--success')).toContainText(target.email);
    await expect(row.locator('.role-badge')).toHaveCount(2);
    await expect(row).toContainText('ems');
    await expect(row).toContainText('nurse');

    // Removing one role leaves the other in place.
    await row.locator('.role-badge', { hasText: 'ems' }).getByRole('button').click();
    await expect(page.locator('.form-message--success')).toContainText('Removed the ems role');
    await expect(row.locator('.role-badge')).toHaveCount(1);
    await expect(row.locator('.role-badge')).toContainText('nurse');
  });
});
