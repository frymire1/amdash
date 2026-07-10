import { test, expect } from '@playwright/test';
import { signUpAndOnboard } from './support/auth';

// The upload form only sources coordinates from the browser's geolocation
// API (no manual lat/lng fields), so a mock position + granted permission is
// required for the mandatory location.latitude / location.longitude fields.
test.use({
  permissions: ['geolocation'],
  geolocation: { latitude: 43.6532, longitude: -79.3832 },
});

test('uploads a mock patient and deletes it', async ({ page }) => {
  await signUpAndOnboard(page, 'ems');

  await expect(page).toHaveURL(/\/$/);
  await expect(page.getByRole('heading', { name: 'EMS Dashboard' })).toBeVisible();

  await page.getByRole('link', { name: 'Add Patient' }).click();
  await expect(page).toHaveURL(/\/upload$/);

  const runId = Date.now();
  const patientName = `E2E Mock Patient ${runId}`;
  await page.getByLabel('Full Name').fill(patientName);
  await page.getByLabel('Healthcare Number').fill(`E2E-${runId}`);

  // Avoid triggering the real Pub/Sub location-tracking pipeline for a
  // throwaway test record — this only exercises upload/list/delete.
  await page.getByRole('switch', { name: 'Live-track this patient' }).click();

  await page.getByRole('button', { name: 'Upload Patient' }).click();

  await expect(page).toHaveURL(/\/$/);
  const card = page.locator('.patient-summary-card', { hasText: patientName });
  await expect(card).toBeVisible();

  await card.getByRole('button', { name: 'Delete' }).click();
  await page.locator('mat-dialog-container').getByRole('button', { name: 'Delete' }).click();

  await expect(page.locator('.patient-summary-card', { hasText: patientName })).toHaveCount(0);
});
