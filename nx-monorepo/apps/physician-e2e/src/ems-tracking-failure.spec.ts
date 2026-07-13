import { APIRequestContext, test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, signUpAndOnboard } from './support/auth';

// Same real deployed EMS hosting site used by live-tracking.spec.ts.
const EMS_ORIGIN = 'https://amdash-ems-dev.web.app';

const API_KEY = 'AIzaSyDHOpM_Mi9NcMeZS8sD42olEMyN_MjVl5k';
const FIRESTORE_BASE = 'https://firestore.googleapis.com/v1/projects/amdash-dev/databases/(default)/documents';

let createdAccount: E2eAccount | undefined;
let createdPatientId: string | undefined;

async function signInForIdToken(request: APIRequestContext, account: E2eAccount): Promise<string> {
  const response = await request.post(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${API_KEY}`,
    { data: { email: account.email, password: account.password, returnSecureToken: true } },
  );
  const body = await response.json();
  return body.idToken;
}

test.afterEach(async ({ request }) => {
  if (createdAccount && createdPatientId) {
    const idToken = await signInForIdToken(request, createdAccount);
    await request.delete(`${FIRESTORE_BASE}/patients/${createdPatientId}`, {
      headers: { Authorization: `Bearer ${idToken}` },
    });
    createdPatientId = undefined;
  }
  if (createdAccount) {
    await deleteAccount(request, createdAccount);
    createdAccount = undefined;
  }
});

test.describe('EMS live-tracking failure', () => {
  test('shows an error dialog and stays on the page when the tracking Cloud Function call fails', async ({
    page,
    context,
  }) => {
    await context.grantPermissions(['geolocation'], { origin: EMS_ORIGIN });
    await context.setGeolocation({ latitude: 43.6532, longitude: -79.3832 });

    // Fails only the tracking publish, not patient upload/onboarding, so the
    // rest of the flow behaves normally and this isolates the tracking
    // failure path specifically.
    await page.route('**/publishEmsLocation**', (route) => route.abort('failed'));

    createdAccount = await signUpAndOnboard(
      page,
      'ems-tracking-failure',
      { firstName: 'E2E', lastName: 'Medic' },
      { origin: EMS_ORIGIN, role: 'ems' },
    );
    await expect(page).toHaveURL(`${EMS_ORIGIN}/`);

    await page.getByRole('link', { name: 'Add Patient' }).click();
    await expect(page).toHaveURL(`${EMS_ORIGIN}/upload`);

    const runId = Date.now();
    await page.getByLabel('Full Name').fill(`E2E Tracking Failure ${runId}`);
    await page.getByLabel('Healthcare Number').fill(`E2E-TRACKFAIL-${runId}`);
    await expect(page.locator('.location-status--shared')).toBeVisible({ timeout: 15000 });

    // Live-track is on by default (patient-upload.component.ts's
    // liveTrackingEnabled signal) — this test relies on that default rather
    // than toggling it explicitly, since the failure only happens on the
    // tracking path.
    await expect(page.getByRole('switch', { name: 'Live-track this patient' })).toHaveAttribute(
      'aria-checked',
      'true',
    );

    await page.getByRole('button', { name: 'Upload Patient' }).click();

    // The button shows a spinner while the (now awaited) tracking call is
    // in flight, not just disabled text.
    await expect(page.locator('.submit-button__spinner')).toBeVisible();

    // The failed tracking call surfaces as a dialog rather than a silent
    // failure or an inline message easy to miss.
    await expect(page.getByRole('heading', { name: 'Live tracking failed' })).toBeVisible({ timeout: 15000 });
    await expect(page.locator('mat-dialog-content')).toContainText('live tracking could not be started');
    await expect(page.locator('mat-dialog-content')).toContainText('check that location permission is enabled');

    // Stays on the upload page — the patient was saved (see cleanup below)
    // but the user isn't bounced home as if everything succeeded.
    await expect(page).toHaveURL(`${EMS_ORIGIN}/upload`);

    // Capture the patient id (now in edit mode) for cleanup via the URL a
    // retry would use, rather than needing a second Firestore query.
    await page.getByRole('button', { name: 'OK' }).click();
    await expect(page.getByRole('heading', { name: 'Live tracking failed' })).toHaveCount(0);

    await page.unroute('**/publishEmsLocation**');
    await page.goto(`${EMS_ORIGIN}/`);
    const card = page.locator('.patient-summary-card', { hasText: `E2E Tracking Failure ${runId}` });
    await expect(card).toBeVisible({ timeout: 15000 });
    const editHref = await card.getByRole('link', { name: 'Edit' }).getAttribute('href');
    createdPatientId = editHref?.split('/').filter(Boolean).pop();
    expect(createdPatientId, 'expected the Edit link to contain the patient id').toBeTruthy();
  });
});
