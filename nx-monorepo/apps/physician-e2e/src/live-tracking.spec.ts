import { APIRequestContext, test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, signUpAndOnboard } from './support/auth';

// This is a genuine cross-app flow: EMS uploads + live-tracks a patient
// through the real deployed Cloud Functions / Pub/Sub pipeline, and the
// physician app is expected to reflect that over a live Firestore listener.
// Both apps are hit on their real deployed hosting URLs (not a local dev
// server) so one page can drive both origins in sequence.
const EMS_ORIGIN = 'https://amdash-ems-dev.web.app';
// This project's playwright.config.mts sets `use.baseURL` to this same URL,
// so calls that omit `{ origin }` (relative `page.goto('/...')`) already
// resolve here regardless of the page's current origin — this constant just
// makes that explicit at the call site below instead of leaving it implicit.
const PHYSICIAN_ORIGIN = 'https://amdash-physician-dev.web.app';

// Same public Web API key already embedded in every app's firebase.ts.
const API_KEY = 'AIzaSyDHOpM_Mi9NcMeZS8sD42olEMyN_MjVl5k';
const FIRESTORE_BASE = 'https://firestore.googleapis.com/v1/projects/amdash-dev/databases/(default)/documents';

test.use({
  geolocation: { latitude: 43.6532, longitude: -79.3832 },
});

// Cleanup state shared between the test body and afterEach below — this
// test writes a real `patients` doc and a real `emsLocations` doc to the
// live amdash-dev Firestore, and nothing in the app itself ever deletes an
// emsLocations doc, so without this they'd accumulate on every run.
let createdPatientId: string | undefined;
let emsAccount: E2eAccount | undefined;
let physicianAccount: E2eAccount | undefined;

async function signInForIdToken(request: APIRequestContext, account: E2eAccount): Promise<string> {
  const response = await request.post(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${API_KEY}`,
    { data: { email: account.email, password: account.password, returnSecureToken: true } },
  );
  const body = await response.json();
  return body.idToken;
}

// This deletes the patient and emsLocations docs created by the test, then
// the two throwaway accounts themselves (Firebase Auth + their Firestore
// users/ doc) — otherwise both accounts and the profile docs are left behind
// permanently, since nothing in the app itself ever deletes a user.
test.afterEach(async ({ request }) => {
  if (emsAccount && createdPatientId) {
    const idToken = await signInForIdToken(request, emsAccount);
    const headers = { Authorization: `Bearer ${idToken}` };
    // Firestore's REST delete is idempotent — safe to call even if the earlier
    // steps failed and one or both docs were never created.
    await Promise.all([
      request.delete(`${FIRESTORE_BASE}/patients/${createdPatientId}`, { headers }),
      request.delete(`${FIRESTORE_BASE}/emsLocations/${createdPatientId}`, { headers }),
    ]);
    createdPatientId = undefined;
  }

  if (emsAccount) {
    await deleteAccount(request, emsAccount);
    emsAccount = undefined;
  }
  if (physicianAccount) {
    await deleteAccount(request, physicianAccount);
    physicianAccount = undefined;
  }
});

// Overrides Date.now() to read as `publishedAtMs + elapsedMs`, then reloads
// so EmsLocationService re-initializes with it already in place (its
// onSnapshot handler re-runs recomputeFreshIds() immediately, no need to
// wait for the 5s recheck interval). Computed off performance.now() (a
// monotonic clock Date-mocking never touches) rather than off the current
// Date.now(), so repeated calls in one test don't compound on top of a
// previous override — each call independently sets an absolute target.
async function mockElapsedTimeSincePublish(page: import('@playwright/test').Page, publishedAtMs: number, elapsedMs: number) {
  const targetEpochMs = publishedAtMs + elapsedMs;
  await page.addInitScript((epoch) => {
    const loadPerf = performance.now();
    Date.now = () => epoch + (performance.now() - loadPerf);
  }, targetEpochMs);
  await page.reload();
}

test('a patient live-tracked by EMS shows as tracked on the physician app, then goes stale once its update is old enough', async ({
  page,
  context,
}) => {
  // Grant geolocation explicitly scoped to the EMS origin. A permission
  // granted via `test.use({ permissions: [...] })` at context-creation time
  // does not reliably carry over once the page navigates to a *different*
  // origin later in the test — this is the more explicit, origin-scoped form.
  await context.grantPermissions(['geolocation'], { origin: EMS_ORIGIN });

  // --- EMS side: upload a patient with live-tracking enabled ---
  emsAccount = await signUpAndOnboard(page, 'ems-tracker', { firstName: 'E2E', lastName: 'Medic' }, { origin: EMS_ORIGIN });
  await expect(page).toHaveURL(`${EMS_ORIGIN}/`);

  await page.getByRole('link', { name: 'Add Patient' }).click();
  await expect(page).toHaveURL(`${EMS_ORIGIN}/upload`);

  // Confirms the mocked geolocation was actually granted/read on this origin
  // before relying on it for the live-tracking publish below.
  await expect(page.locator('.location-status--shared')).toBeVisible({ timeout: 15000 });

  // Both name and healthcare number must be unique per run: the physician
  // app's patient list tracks each @for row by patient.id now, but this test
  // shouldn't rely on that — a duplicate healthcareNumber across leftover
  // runs is exactly what exposed that bug (see patient-list.component.html).
  const runId = Date.now();
  const patientName = `E2E Tracked Patient ${runId}`;
  await page.getByLabel('Full Name').fill(patientName);
  await page.getByLabel('Healthcare Number').fill(`E2E-TRACK-${runId}`);

  // Explicitly ensure "Live-track this patient" is on — this is what
  // publishes a real location update through publishEmsLocation -> Pub/Sub ->
  // onEmsLocationEvent -> Firestore emsLocations/{patientId}. Checked/clicked
  // rather than assumed, so this test doesn't silently depend on the app's
  // default (patient-upload.component.ts's `liveTrackingEnabled` signal).
  const liveTrackToggle = page.getByRole('switch', { name: 'Live-track this patient' });
  await expect(liveTrackToggle).toBeVisible();
  if ((await liveTrackToggle.getAttribute('aria-checked')) !== 'true') {
    await liveTrackToggle.click();
  }
  await expect(liveTrackToggle).toHaveAttribute('aria-checked', 'true');

  // Node-side wall clock (this test process, never touched by the browser-side
  // Date mocking below) — an approximation of when EMS's publish fires.
  const publishedAtMs = Date.now();
  await page.getByRole('button', { name: 'Upload Patient' }).click();
  await expect(page).toHaveURL(`${EMS_ORIGIN}/`);

  // Capture the Firestore-generated patient ID (same ID emsLocations ends up
  // keyed by) for cleanup, via the summary card's Edit link (routerLink
  // ['/upload', uploaded.id] renders as href="/upload/{id}") — avoids an
  // extra Firestore query just to look it up later.
  const emsCard = page.locator('.patient-summary-card', { hasText: patientName });
  await expect(emsCard).toBeVisible({ timeout: 15000 });
  const editHref = await emsCard.getByRole('link', { name: 'Edit' }).getAttribute('href');
  createdPatientId = editHref?.split('/').filter(Boolean).pop();
  expect(createdPatientId, 'expected the Edit link to contain the new patient id').toBeTruthy();

  // EmsTrackingService.startTracking() -> publishCurrentPosition() is
  // fire-and-forget: it kicks off navigator.geolocation.getCurrentPosition()
  // and never gets awaited anywhere in the call chain up through onSubmit().
  // The very next step below is a full cross-origin page.goto() (unlike the
  // app's own in-SPA router.navigate(['/'])), which destroys this page's JS
  // context outright. Without this wait, that navigation can — and observably
  // does — happen before the geolocation callback fires and the actual
  // publishEmsLocation call goes out, meaning the location update is never
  // even sent, not just slow to arrive.
  await page.waitForTimeout(3000);

  // --- Physician side: the same patient should show up as actively tracked ---
  physicianAccount = await signUpAndOnboard(
    page,
    'physician-tracker',
    { firstName: 'E2E', lastName: 'Doctor' },
    { origin: PHYSICIAN_ORIGIN },
  );
  await expect(page).toHaveURL(`${PHYSICIAN_ORIGIN}/physician`);

  // main-view.component.html renders <app-patient-list> twice — once inside
  // .patient-list-panel (a mobile drawer, display:none by default) and once
  // inside .patient-list-section (the desktop panel, visible at this test's
  // viewport width). Every patient card exists as two DOM nodes; scope to
  // the desktop section specifically so this doesn't match the hidden copy.
  const card = page.locator('.patient-list-section .patient-card', { hasText: patientName });

  // Fake-advance to 15s post-publish (well under the 35s STALE_AFTER_MS) before
  // the first check, rather than relying on whatever real wall-clock time the
  // steps above happened to take.
  await mockElapsedTimeSincePublish(page, publishedAtMs, 15_000);

  // The EMS publish is a real Cloud Function + Pub/Sub round trip, so give it
  // real time to land in Firestore and reach the physician app's listener,
  // even though the client's own clock now reads as 15s post-publish.
  await expect(card.locator('.patient-card__tracking-dot')).toBeVisible({ timeout: 30000 });

  // --- Mock further forward past STALE_AFTER_MS (35s, see ems-location.service.ts)
  // without waiting that long in real time, and confirm it goes stale.
  await mockElapsedTimeSincePublish(page, publishedAtMs, 40_000);

  await expect(card.locator('.patient-card__tracking-dot')).toHaveCount(0);
});
