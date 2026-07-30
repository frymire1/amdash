import { test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, generateE2eAccount, signUpAndOnboard } from './support/auth';
import { createOrganizationWithAdmin, deleteAccountByEmail, deleteOrganizationByName } from './support/admin';

// The account driving each test below is itself just another throwaway e2e
// account, granted 'super-admin' or 'admin' via the Admin SDK the same way
// role-assignment.spec.ts grants 'admin' — the app's own UI has no
// self-granting path for either role, but that's a client-side restriction,
// not one that applies to this Admin-SDK-backed test setup.
let createdAdminAccount: E2eAccount | undefined;
let createdOrganizationName: string | undefined;
let createdOrganizationAdminEmail: string | undefined;

test.afterEach(async () => {
  if (createdOrganizationName) {
    await deleteOrganizationByName(createdOrganizationName);
    createdOrganizationName = undefined;
  }
  if (createdOrganizationAdminEmail) {
    await deleteAccountByEmail(createdOrganizationAdminEmail);
    createdOrganizationAdminEmail = undefined;
  }
  if (createdAdminAccount) {
    await deleteAccount(createdAdminAccount);
    createdAdminAccount = undefined;
  }
});

test.describe('organization management', () => {
  test('a super-admin can create an organization with its first admin', async ({ page }) => {
    await signUpAndOnboard(page, 'org-super-admin', undefined, {
      role: 'super-admin',
      onAccountCreated: (account) => (createdAdminAccount = account),
    });
    await expect(page.getByRole('heading', { name: 'Organization Management' })).toBeVisible();

    // Drive the hamburger menu itself rather than page.goto('/organizations')
    // directly, so this also exercises the nav-bar link, not just the route.
    await page.getByRole('button', { name: 'Open navigation menu' }).click();
    await page.getByRole('menuitem', { name: 'Organizations' }).click();
    await expect(page.getByRole('heading', { name: 'Organization Management' })).toBeVisible();

    const organizationName = `E2E Test Org ${Date.now()}`;
    const adminAccount = generateE2eAccount('org-admin');
    createdOrganizationName = organizationName;
    createdOrganizationAdminEmail = adminAccount.email;

    await page.getByLabel('Organization Name').fill(organizationName);
    await page.getByLabel('Admin Email').fill(adminAccount.email);
    await page.getByLabel('Admin First Name').fill('E2E');
    await page.getByLabel('Admin Last Name').fill('OrgAdmin');
    await page.getByRole('button', { name: 'Create Organization' }).click();
    await expect(page.locator('.submit-button__spinner')).toBeVisible();

    await expect(page.locator('.form-message--success')).toContainText(organizationName);
    await expect(page.locator('.form-message--success')).toContainText(adminAccount.email);
    const row = page.locator('.organizations-table tbody tr', { hasText: organizationName });
    await expect(row).toBeVisible();
  });

  test('creating an organization with empty fields does not submit', async ({ page }) => {
    await signUpAndOnboard(page, 'org-super-admin-empty', undefined, {
      role: 'super-admin',
      onAccountCreated: (account) => (createdAdminAccount = account),
    });
    await expect(page.getByRole('heading', { name: 'Organization Management' })).toBeVisible();

    // organizations() (organization-management.component.ts) starts as an
    // empty signal and only fills in once the Firestore listener's first
    // snapshot arrives — reading .count() before that lands races the real
    // data and reads 0 regardless of how many organizations actually exist.
    // Waiting for the first row to render (test-org always exists post-
    // migration) guarantees the snapshot has landed before the count below
    // is captured — same reasoning as hospital-management.spec.ts's own
    // fix for the identical race.
    await expect(page.locator('.organizations-table tbody tr').first()).toBeVisible();
    const rowCountBefore = await page.locator('.organizations-table tbody tr').count();

    await page.getByRole('button', { name: 'Create Organization' }).click();

    // onCreateOrganization() returns early on an invalid form (see
    // organization-management.component.ts) — no success message, no new row.
    await expect(page.locator('.form-message--success')).toHaveCount(0);
    await expect(page.locator('.organizations-table tbody tr')).toHaveCount(rowCountBefore);
  });

  // The whole point of this feature: confirmed via the real admin UI (the
  // "Assign a Role" form), not by reaching into Firestore internals directly.
  // Exercises both the per-target check added to setUserRole (the assignment
  // itself gets rejected) and the query-scoping added to listUsersWithRoles
  // (the other org's user never even appears in this admin's own table).
  test('an admin cannot see or modify a user from a different organization', async ({ page }) => {
    const otherOrgName = `E2E Isolation Org ${Date.now()}`;
    const otherOrgAdmin = generateE2eAccount('other-org-admin');
    createdOrganizationName = otherOrgName;
    createdOrganizationAdminEmail = otherOrgAdmin.email;
    await createOrganizationWithAdmin(otherOrgName, otherOrgAdmin.email, otherOrgAdmin.password);

    await signUpAndOnboard(page, 'isolation-admin', undefined, {
      role: 'admin',
      onAccountCreated: (account) => (createdAdminAccount = account),
    });
    await expect(page.getByRole('heading', { name: 'User Management' })).toBeVisible();

    await expect(page.locator('.users-table')).not.toContainText(otherOrgAdmin.email);

    const assignRoleForm = page.locator('h3:has-text("Assign a Role") + form');
    await assignRoleForm.getByLabel('User email').fill(otherOrgAdmin.email);
    await assignRoleForm.getByLabel('Role').click();
    await page.getByRole('option', { name: 'EMS' }).click();
    await assignRoleForm.getByRole('button', { name: 'Assign Role' }).click();

    await expect(page.locator('.form-message--error')).toContainText('not a member of your organization');
  });
});
