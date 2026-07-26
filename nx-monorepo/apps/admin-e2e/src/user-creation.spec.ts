import { Locator, Page, test, expect } from '@playwright/test';
import { createPasswordlessAccount, deleteAccountByEmail } from './support/admin';
import { generateE2eAccount, signIn } from './support/auth';

// Needs a real, pre-existing admin account (role: 'admin' set by hand in the
// Firestore console) since nothing can self-grant that role anymore — same
// constraint as role-assignment.spec.ts. Distinct from that file: this
// exercises the "Add User" form itself (the createUser callable), not the
// "Assign a Role" form (setUserRole) — role-assignment.spec.ts's target
// account is always created via the Admin SDK directly, so the createUser
// callable driven through its own UI form had no coverage until now.
const ADMIN_EMAIL = process.env['E2E_ADMIN_EMAIL'];
const ADMIN_PASSWORD = process.env['E2E_ADMIN_PASSWORD'];

let createdEmail: string | undefined;

test.afterEach(async () => {
  if (!createdEmail) {
    return;
  }
  await deleteAccountByEmail(createdEmail);
  createdEmail = undefined;
});

// The "Add User" and "Assign a Role" forms sit on the same page and both
// happen to label a field "Email"/"User email" and "Role" — "Role" is an
// exact duplicate across the two, so an unscoped getByLabel('Role') is
// ambiguous. Scoping to the form immediately following the "Add User"
// heading sidesteps that instead of relying on exact-text tricks.
function addUserForm(page: Page): Locator {
  return page.locator('h3:has-text("Add User") + form');
}

test.describe('admin user creation', () => {
  test.skip(
    !ADMIN_EMAIL || !ADMIN_PASSWORD,
    'Set E2E_ADMIN_EMAIL / E2E_ADMIN_PASSWORD to an existing admin account to run these tests.',
  );

  test('an admin can create a new user with a role, and they appear in the table', async ({ page }) => {
    const account = generateE2eAccount('created-by-admin');
    createdEmail = account.email;

    await signIn(page, { email: ADMIN_EMAIL as string, password: ADMIN_PASSWORD as string });
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible();

    const form = addUserForm(page);
    await form.getByLabel('Email').fill(account.email);
    await form.getByLabel('First name').fill('E2E');
    await form.getByLabel('Last name').fill('Created');
    await form.getByLabel('Role').click();
    await page.getByRole('option', { name: 'Physician' }).click();
    await form.getByRole('button', { name: 'Add User' }).click();

    await expect(page.locator('.form-message--success')).toContainText(account.email);

    const row = page.locator('.users-table tbody tr', { hasText: account.email });
    await expect(row).toBeVisible();
    await expect(row).toContainText('E2E Created');
    await expect(row.locator('.role-badge')).toContainText('physician');
  });

  test('creating a user with an email that already exists shows an error', async ({ page }) => {
    const account = generateE2eAccount('duplicate');
    createdEmail = account.email;
    await createPasswordlessAccount(account.email);

    await signIn(page, { email: ADMIN_EMAIL as string, password: ADMIN_PASSWORD as string });
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible();

    const form = addUserForm(page);
    await form.getByLabel('Email').fill(account.email);
    await form.getByLabel('First name').fill('E2E');
    await form.getByLabel('Last name').fill('Duplicate');
    await form.getByLabel('Role').click();
    await page.getByRole('option', { name: 'Nurse' }).click();
    await form.getByRole('button', { name: 'Add User' }).click();

    await expect(page.locator('.form-message--error')).toContainText(`An account with ${account.email} already exists.`);
  });
});
