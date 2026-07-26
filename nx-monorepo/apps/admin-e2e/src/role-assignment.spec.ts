import { Locator, Page, test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, logOut, signIn, signUpAndOnboard } from './support/auth';

// This test needs a real, pre-existing admin account (role: 'admin' set by
// hand in the Firestore console) since nothing can self-grant that role
// anymore. Point it at your own admin dev account to exercise this path.
const ADMIN_EMAIL = process.env['E2E_ADMIN_EMAIL'];
const ADMIN_PASSWORD = process.env['E2E_ADMIN_PASSWORD'];

// The "Add User" form (user-creation.spec.ts) sits on the same page and also
// labels a field "Role" — an unscoped getByLabel('Role') is ambiguous
// between the two. Scope to the form immediately following the "Assign a
// Role" heading instead.
function assignRoleForm(page: Page): Locator {
  return page.locator('h3:has-text("Assign a Role") + form');
}

let createdTarget: E2eAccount | undefined;

test.afterEach(async () => {
  if (!createdTarget) {
    return;
  }
  await deleteAccount(createdTarget);
  createdTarget = undefined;
});

test.describe('admin role assignment', () => {
  test.skip(
    !ADMIN_EMAIL || !ADMIN_PASSWORD,
    'Set E2E_ADMIN_EMAIL / E2E_ADMIN_PASSWORD to an existing admin account to run this test.',
  );

  test('an admin can assign multiple roles to another user by email, then remove one', async ({ page }) => {
    // Create a disposable target account to assign roles to, rather than
    // mutating the admin fixture account's own roles.
    const target = await signUpAndOnboard(page, 'admin-target', undefined, {
      onAccountCreated: (account) => (createdTarget = account),
    });
    await logOut(page);

    await signIn(page, { email: ADMIN_EMAIL as string, password: ADMIN_PASSWORD as string });
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible();

    const row = page.locator('.users-table tbody tr', { hasText: target.email });
    const form = assignRoleForm(page);

    await form.getByLabel('User email').fill(target.email);
    await form.getByLabel('Role').click();
    await page.getByRole('option', { name: 'EMS' }).click();
    await form.getByRole('button', { name: 'Assign Role' }).click();
    await expect(page.locator('.form-message--success')).toContainText(target.email);
    await expect(row.locator('.role-badge')).toHaveCount(1);
    await expect(row.locator('.role-badge')).toContainText('ems');

    // A second, different role should add alongside the first rather than
    // replace it — this is the whole point of role now being an array.
    await form.getByLabel('User email').fill(target.email);
    await form.getByLabel('Role').click();
    await page.getByRole('option', { name: 'Nurse' }).click();
    await form.getByRole('button', { name: 'Assign Role' }).click();
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
