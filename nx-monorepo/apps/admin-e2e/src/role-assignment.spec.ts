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

  test('an admin can assign a role to another user by email', async ({ page }) => {
    // Create a disposable target account to assign a role to, rather than
    // mutating the admin fixture account's own role.
    const target = await signUpAndOnboard(page, 'admin-target');
    await logOut(page);

    await signIn(page, { email: ADMIN_EMAIL as string, password: ADMIN_PASSWORD as string });
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible();

    await page.getByLabel('User email').fill(target.email);
    await page.getByLabel('Role').click();
    await page.getByRole('option', { name: 'EMS' }).click();
    await page.getByRole('button', { name: 'Assign Role' }).click();

    await expect(page.locator('.form-message--success')).toContainText(target.email);

    const row = page.locator('.users-table tbody tr', { hasText: target.email });
    await expect(row.locator('.role-badge')).toHaveText('ems');
  });
});
