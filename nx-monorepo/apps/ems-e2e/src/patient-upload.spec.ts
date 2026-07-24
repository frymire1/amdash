import { Page, test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, signUpAndOnboard } from './support/auth';

// The upload form only sources coordinates from the browser's geolocation
// API (no manual lat/lng fields), so a mock position + granted permission is
// required for it to populate.
test.use({
  permissions: ['geolocation'],
  geolocation: { latitude: 43.6532, longitude: -79.3832 },
});

// Otherwise the account and its Firestore users/ doc are left behind
// permanently, since nothing in the app itself ever deletes a user.
let createdAccount: E2eAccount | undefined;

test.afterEach(async () => {
  if (!createdAccount) {
    return;
  }
  await deleteAccount(createdAccount);
  createdAccount = undefined;
});

test('uploads a mock patient and deletes it', async ({ page }) => {
  await signUpAndOnboard(page, 'ems', undefined, {
    role: 'ems',
    onAccountCreated: (account) => (createdAccount = account),
  });

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

interface PatientFormValues {
  name: string;
  gender: string;
  age: string;
  healthcareNumber: string;
  destination: string;
  heartRate: string;
  bloodPressure: string;
  oxygen: string;
  temperature: string;
  respiratoryRate: string;
  gcs: string;
  ivSize: string;
  ivPlacement: string;
  treatment: string;
  notes: string;
}

// Opens a mat-select and picks an option.
async function selectMatOption(page: Page, label: string, optionText: string) {
  // force: true — an empty, never-focused mat-select rests its floating
  // label directly over the trigger's click point (it hasn't animated out
  // of the way yet, since nothing has focused or filled it), which fails
  // Playwright's normal actionability check even though the resolved
  // element is exactly right. A real click on the same spot would still
  // open the select in a browser.
  await page.getByLabel(label).click({ force: true });
  await page.getByRole('option', { name: optionText, exact: true }).click();
  // Wait for the CDK overlay backdrop to fully detach (its exit animation)
  // before returning — opening a second mat-select before that finishes can
  // leave a stray backdrop from this one intercepting clicks on the next
  // field.
  await expect(page.locator('.cdk-overlay-backdrop')).toHaveCount(0);
}

async function fillPatientForm(page: Page, values: PatientFormValues) {
  await page.getByLabel('Full Name').fill(values.name);
  await selectMatOption(page, 'Gender', values.gender);
  await page.getByLabel('Age').fill(values.age);
  await page.getByLabel('Healthcare Number').fill(values.healthcareNumber);
  await selectMatOption(page, 'Destination Hospital', values.destination);
  await page.getByLabel('Heart Rate (bpm)').fill(values.heartRate);
  await page.getByLabel('Blood Pressure').fill(values.bloodPressure);
  await page.getByLabel('Oxygen (%)').fill(values.oxygen);
  await page.getByLabel('Temperature (°C)').fill(values.temperature);
  await page.getByLabel('Respiratory Rate (breaths/min)').fill(values.respiratoryRate);
  await page.getByLabel('GCS').fill(values.gcs);
  await selectMatOption(page, 'IV Size (Gauge)', values.ivSize);
  await selectMatOption(page, 'IV Placement', values.ivPlacement);
  await page.getByLabel('Treatment / Medication Given').fill(values.treatment);
  await page.getByLabel('Patient Notes').fill(values.notes);
}

// mat-select doesn't render a native <select>/<input> value — the chosen
// option's text ends up as the combobox trigger's own text content, so this
// reads selects back with toHaveText rather than toHaveValue.
async function expectPatientFormValues(page: Page, values: PatientFormValues) {
  await expect(page.getByLabel('Full Name')).toHaveValue(values.name);
  await expect(page.getByLabel('Gender')).toHaveText(values.gender);
  await expect(page.getByLabel('Age')).toHaveValue(values.age);
  await expect(page.getByLabel('Healthcare Number')).toHaveValue(values.healthcareNumber);
  await expect(page.getByLabel('Destination Hospital')).toHaveText(values.destination);
  await expect(page.getByLabel('Heart Rate (bpm)')).toHaveValue(values.heartRate);
  await expect(page.getByLabel('Blood Pressure')).toHaveValue(values.bloodPressure);
  await expect(page.getByLabel('Oxygen (%)')).toHaveValue(values.oxygen);
  await expect(page.getByLabel('Temperature (°C)')).toHaveValue(values.temperature);
  await expect(page.getByLabel('Respiratory Rate (breaths/min)')).toHaveValue(values.respiratoryRate);
  await expect(page.getByLabel('GCS')).toHaveValue(values.gcs);
  await expect(page.getByLabel('IV Size (Gauge)')).toHaveText(values.ivSize);
  await expect(page.getByLabel('IV Placement')).toHaveText(values.ivPlacement);
  await expect(page.getByLabel('Treatment / Medication Given')).toHaveValue(values.treatment);
  await expect(page.getByLabel('Patient Notes')).toHaveValue(values.notes);
}

test('fills every field on upload, then edits every field and confirms the new values persist', async ({ page }) => {
  // This fills and verifies every field twice (create, then update), each
  // pass driving 4 mat-selects (each with its own overlay-close wait) plus
  // 11 other fields — heavier than every other test in this suite, so it
  // gets its own override above and beyond playwright.config.mts's `timeout`.
  test.setTimeout(90000);

  await signUpAndOnboard(page, 'ems', undefined, {
    role: 'ems',
    onAccountCreated: (account) => (createdAccount = account),
  });
  await expect(page).toHaveURL(/\/$/);

  await page.getByRole('link', { name: 'Add Patient' }).click();
  await expect(page).toHaveURL(/\/upload$/);

  // Avoid triggering the real Pub/Sub location-tracking pipeline for a
  // throwaway test record. Not re-toggled on the edit pass below: since
  // tracking was never actually started, the form reloads with this already
  // off (see PatientUploadComponent's constructor, which seeds it from
  // EmsTrackingService.isTracking(id)).
  await page.getByRole('switch', { name: 'Live-track this patient' }).click();

  const runId = Date.now();
  const initial: PatientFormValues = {
    name: `E2E Full Patient ${runId}`,
    gender: 'Female',
    age: '34',
    healthcareNumber: `E2E-${runId}`,
    destination: 'General Hospital',
    heartRate: '88',
    bloodPressure: '120/80',
    oxygen: '98',
    // Deliberately not a whole number (e.g. "37.0") — a plain number input
    // round-trips that as "37", which would make the persistence check
    // below fail for a reason that has nothing to do with what it's
    // actually testing.
    temperature: '37.5',
    respiratoryRate: '16',
    gcs: '15',
    ivSize: '18G',
    ivPlacement: 'Right Antecubital (AC)',
    treatment: 'Administered 1L NS IV fluid bolus.',
    notes: 'Initial notes.',
  };

  await fillPatientForm(page, initial);
  await page.getByRole('button', { name: 'Upload Patient' }).click();
  await expect(page).toHaveURL(/\/$/);

  const initialCard = page.locator('.patient-summary-card', { hasText: initial.name });
  await expect(initialCard).toBeVisible();

  // Re-open the edit form rather than trusting the form's own in-memory
  // state — this confirms every field actually round-tripped through
  // Firestore as entered, not just that the form accepted the input.
  await initialCard.getByRole('link', { name: 'Edit' }).click();
  await expect(page).toHaveURL(/\/upload\/.+/);
  await expectPatientFormValues(page, initial);

  const updated: PatientFormValues = {
    name: `E2E Full Patient Updated ${runId}`,
    gender: 'Male',
    age: '45',
    healthcareNumber: `E2E-UPDATED-${runId}`,
    destination: "St. Mary's Medical Center",
    heartRate: '102',
    bloodPressure: '130/85',
    oxygen: '95',
    temperature: '38.2',
    respiratoryRate: '22',
    gcs: '13',
    ivSize: '22G',
    ivPlacement: 'Left Forearm',
    treatment: 'Administered 4mg ondansetron IV.',
    notes: 'Updated notes.',
  };

  await fillPatientForm(page, updated);
  await page.getByRole('button', { name: 'Save Changes' }).click();
  await expect(page).toHaveURL(/\/$/);

  const updatedCard = page.locator('.patient-summary-card', { hasText: updated.name });
  await expect(updatedCard).toBeVisible();

  // Same reasoning as above: re-open to confirm the update actually
  // persisted every field's new value, not just the ones that happened to
  // change.
  await updatedCard.getByRole('link', { name: 'Edit' }).click();
  await expect(page).toHaveURL(/\/upload\/.+/);
  await expectPatientFormValues(page, updated);

  await page.goto('/');
  const finalCard = page.locator('.patient-summary-card', { hasText: updated.name });
  await finalCard.getByRole('button', { name: 'Delete' }).click();
  await page.locator('mat-dialog-container').getByRole('button', { name: 'Delete' }).click();
  await expect(page.locator('.patient-summary-card', { hasText: updated.name })).toHaveCount(0);
});
