import { test, expect } from '@playwright/test';
import { signUpAndOnboard, signIn, E2eAccount } from './support/auth';

// Same real deployed EMS hosting site used by live-tracking.spec.ts.
const EMS_ORIGIN = 'https://amdash-ems-dev.web.app';

test.describe('EMS patient card live update', () => {
  test('editing a patient updates the home list without a manual reload, for the editor and for another session', async ({
    browser,
  }) => {
    // Two separate browser contexts standing in for two EMS devices signed
    // into the same account: A submits the edit, B is already sitting on the
    // home list and should pick up the change purely via the Firestore
    // onSnapshot listener, with no navigation or reload of its own.
    const contextA = await browser.newContext({ permissions: ['geolocation'], geolocation: { latitude: 43.6532, longitude: -79.3832 } });
    const contextB = await browser.newContext({ permissions: ['geolocation'], geolocation: { latitude: 43.6532, longitude: -79.3832 } });
    const pageA = await contextA.newPage();
    const pageB = await contextB.newPage();

    const account: E2eAccount = await signUpAndOnboard(
      pageA,
      'ems-live-update',
      { firstName: 'E2E', lastName: 'Medic' },
      { origin: EMS_ORIGIN },
    );
    await expect(pageA).toHaveURL(`${EMS_ORIGIN}/`);

    // Session A uploads a patient.
    await pageA.getByRole('link', { name: 'Add Patient' }).click();
    await expect(pageA).toHaveURL(`${EMS_ORIGIN}/upload`);

    const runId = Date.now();
    const originalName = `E2E Live Update ${runId}`;
    await pageA.getByLabel('Full Name').fill(originalName);
    await pageA.getByLabel('Healthcare Number').fill(`E2E-LIVE-${runId}`);
    await expect(pageA.locator('.location-status--shared')).toBeVisible({ timeout: 15000 });

    await pageA.getByRole('button', { name: 'Upload Patient' }).click();
    await expect(pageA).toHaveURL(`${EMS_ORIGIN}/`);

    const cardA = pageA.locator('.patient-summary-card', { hasText: originalName });
    await expect(cardA).toBeVisible({ timeout: 15000 });

    // Session B signs in separately with the same account and lands on the
    // home list, then just stays there — no reload, no re-navigation.
    await signIn(pageB, account, { origin: EMS_ORIGIN });
    await expect(pageB).toHaveURL(`${EMS_ORIGIN}/`);
    const cardB = pageB.locator('.patient-summary-card', { hasText: originalName });
    await expect(cardB).toBeVisible({ timeout: 15000 });

    // Session A edits the patient's name (a field rendered on the summary
    // card) and saves.
    await cardA.getByRole('link', { name: 'Edit' }).click();
    await expect(pageA).toHaveURL(new RegExp(`${EMS_ORIGIN}/upload/.+`));

    const updatedName = `E2E Live Update UPDATED ${runId}`;
    await pageA.getByLabel('Full Name').fill(updatedName);
    await pageA.getByRole('button', { name: 'Save Changes' }).click();
    await expect(pageA).toHaveURL(`${EMS_ORIGIN}/`);

    // The editor's own home list should reflect the change without a reload.
    await expect(pageA.locator('.patient-summary-card', { hasText: updatedName })).toBeVisible({ timeout: 10000 });

    // The other, already-open session should also pick up the change live.
    await expect(pageB.locator('.patient-summary-card', { hasText: updatedName })).toBeVisible({ timeout: 10000 });

    // Cleanup: delete the patient via session A's UI. The confirm click is
    // scoped to the dialog itself — an unscoped getByRole('button', { name:
    // 'Delete' }) also matches every other patient card's own Delete button
    // still present in the background DOM behind the dialog overlay.
    await pageA.locator('.patient-summary-card', { hasText: updatedName }).getByRole('button', { name: 'Delete' }).click();
    await pageA.getByLabel('Delete patient?').getByRole('button', { name: 'Delete' }).click();

    await contextA.close();
    await contextB.close();
  });
});
