import { Page, test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, generateE2eAccount, signUpAndOnboard } from './support/auth';
import { createAccountWithPassword, deletePatientData } from './support/admin';

// The upload form only sources coordinates from the browser's geolocation
// API (no manual lat/lng fields), so a mock position + granted permission is
// required for it to populate.
test.use({
  permissions: ['geolocation'],
  geolocation: { latitude: 43.6532, longitude: -79.3832 },
});

// Otherwise the account and its Firestore users/ doc are left behind
// permanently, since nothing in the app itself ever deletes a user. Both
// tests below also delete the patient via the UI's own delete button as part
// of the flow they're testing — but that only runs if every prior step
// succeeds. Capturing the patient id as soon as it exists and clearing it
// here too (deletePatientData is idempotent) means a mid-test failure still
// can't leave a `patients` doc behind.
//
// Toggling "Live-track this patient" off does NOT avoid emsLocations writes
// entirely, despite that being the original intent here — PatientUploadComponent's
// onSubmit() still fires trackingService.stopTracking(id) on the "off" branch
// (patient-upload.component.ts), which calls the stopEmsLocation Cloud
// Function and writes emsLocations/{id} with `active: false`. That call is
// fire-and-forget, same as the live-tracking "start" path live-tracking.spec.ts
// already has to wait out — without the same wait here, this file's own
// afterEach could run deletePatientData before that write lands, leaving an
// orphaned emsLocations doc behind despite the test itself passing.
let createdAccount: E2eAccount | undefined;
let createdPatientId: string | undefined;

test.afterEach(async () => {
  if (createdPatientId) {
    await deletePatientData(createdPatientId);
    createdPatientId = undefined;
  }
  if (createdAccount) {
    await deleteAccount(createdAccount);
    createdAccount = undefined;
  }
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

  // Turned off so this test doesn't rely on the real live-tracking pipeline
  // for a throwaway record — but see the file-level comment above: this
  // still fires a fire-and-forget stopEmsLocation call on submit.
  await page.getByRole('switch', { name: 'Live-track this patient' }).click();

  await page.getByRole('button', { name: 'Upload Patient' }).click();
  await expect(page.locator('.submit-button__spinner')).toBeVisible();
  await expect(page).toHaveURL(/\/$/);

  // Gives the fire-and-forget stopEmsLocation call (see the file-level
  // comment above) time to actually land before this test's own cleanup
  // runs — same reasoning as live-tracking.spec.ts's wait after its publish.
  await page.waitForTimeout(3000);

  const card = page.locator('.patient-summary-card', { hasText: patientName });
  await expect(card).toBeVisible();

  // Read the id off the Edit link's href (routerLink ['/upload', id] renders
  // as href="/upload/{id}") without navigating there, so afterEach can clean
  // this record up even if the delete steps below never run.
  const editHref = await card.getByRole('link', { name: 'Edit' }).getAttribute('href');
  createdPatientId = editHref?.split('/').filter(Boolean).pop();
  expect(createdPatientId, 'expected the Edit link to contain the new patient id').toBeTruthy();

  await card.getByRole('button', { name: 'Delete' }).click();
  await page.locator('mat-dialog-container').getByRole('button', { name: 'Delete' }).click();

  await expect(page.locator('.patient-summary-card', { hasText: patientName })).toHaveCount(0);
});

// uploadPatient() (patient-upload.service.ts) goes through Firestore's Write
// WebChannel — a long-lived, multiplexed connection the client keeps open
// and reuses across writes once established. signUpAndOnboard() drives a
// real saveProfile() write via user-settings before this test ever runs,
// which would open that channel well before this test registers its
// interception — meaning this write could go out over that already-open
// connection instead of a fresh request the interception would catch, and
// silently succeed anyway. Using createAccountWithPassword to skip straight
// to a real Sign In means this is the very first Firestore write of the
// whole browser session, so there's no such connection yet to reuse.
//
// This isn't a contrived edge case: EMS crews submit patient data from
// ambulances and other locations with unreliable cellular coverage, so a
// write hanging mid-submission in the field is a realistic failure mode for
// this app specifically. Aborting the request here faithfully reproduces
// what a real dropped connection does — but NOT as an immediate rejection:
// Firestore's client SDK never rejects a blocked write, it retries
// indefinitely instead (confirmed by watching an equivalent test hang on its
// "Uploading…" spinner for 45+ seconds with no error, before with-timeout.ts
// existed). Without with-timeout.ts's 15s bound, a medic in a dead zone
// could tap "Upload Patient" and watch it spin forever with no way to know
// the record was never saved, let alone retry.
test('shows an error if the upload fails, without navigating away', async ({ page }) => {
  test.setTimeout(60000);

  const account = generateE2eAccount('upload-fail');
  createdAccount = account;
  await createAccountWithPassword(account.email, account.password, 'ems');

  await page.goto('/login');
  await page.getByLabel('Email').fill(account.email);
  await page.getByRole('button', { name: 'Continue' }).click();
  await page.getByRole('button', { name: 'Sign In' }).waitFor();
  await page.getByLabel('Password', { exact: true }).fill(account.password);
  await page.getByRole('button', { name: 'Sign In' }).click();
  await expect(page).toHaveURL(/\/$/, { timeout: 15000 });

  await page.getByRole('link', { name: 'Add Patient' }).click();
  await expect(page).toHaveURL(/\/upload$/);

  const runId = Date.now();
  await page.getByLabel('Full Name').fill(`E2E Upload Fail ${runId}`);
  await page.getByLabel('Healthcare Number').fill(`E2E-FAIL-${runId}`);
  await page.getByRole('switch', { name: 'Live-track this patient' }).click();

  await page.route('**/Write/channel**', (route) => route.abort('failed'));

  await page.getByRole('button', { name: 'Upload Patient' }).click();
  await expect(page.locator('.submit-button__spinner')).toBeVisible();
  await expect(page.locator('.form-message--error')).toHaveText(
    'This is taking longer than expected. Check your connection and try again.',
    { timeout: 20000 },
  );
  await expect(page).toHaveURL(/\/upload$/);

  await page.unroute('**/Write/channel**');
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

  // Turned off so this test doesn't rely on the real live-tracking pipeline
  // for a throwaway record — but see the file-level comment above: this
  // still fires a fire-and-forget stopEmsLocation call on every submit below.
  // Not re-toggled on the edit pass below: since tracking was never actually
  // started, the form reloads with this already off (see
  // PatientUploadComponent's constructor, which seeds it from
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
  await expect(page.locator('.submit-button__spinner')).toBeVisible();
  await expect(page).toHaveURL(/\/$/);

  const initialCard = page.locator('.patient-summary-card', { hasText: initial.name });
  await expect(initialCard).toBeVisible();

  // Same reasoning as the other test in this file: capture the id now, right
  // after the doc first exists, so afterEach can clean it up even if a later
  // step (the edit pass, or the final delete) fails first. The id doesn't
  // change across the edit below — it's an update to the same doc, not a
  // new one.
  const editHref = await initialCard.getByRole('link', { name: 'Edit' }).getAttribute('href');
  createdPatientId = editHref?.split('/').filter(Boolean).pop();
  expect(createdPatientId, 'expected the Edit link to contain the new patient id').toBeTruthy();

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
  await expect(page.locator('.submit-button__spinner')).toBeVisible();
  await expect(page).toHaveURL(/\/$/);

  // Gives this submit's own fire-and-forget stopEmsLocation call (see the
  // file-level comment above) time to land before this test's cleanup runs.
  await page.waitForTimeout(3000);

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
