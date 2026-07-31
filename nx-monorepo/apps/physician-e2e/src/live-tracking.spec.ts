import { test, expect } from '@playwright/test';
import { E2eAccount, deleteAccount, signUpAndOnboard } from './support/auth';
import { deletePatientData, getEmsLocationUpdatedAtMs } from './support/admin';

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

// This deletes the patient and emsLocations docs created by the test, then
// the two throwaway accounts themselves (Firebase Auth + their Firestore
// users/ doc) — otherwise both accounts and the profile docs are left behind
// permanently, since nothing in the app itself ever deletes a user.
test.afterEach(async () => {
  if (createdPatientId) {
    // Firestore deletes are idempotent — safe to call even if the earlier
    // steps failed and one or both docs were never created.
    await deletePatientData(createdPatientId);
    createdPatientId = undefined;
  }

  if (emsAccount) {
    await deleteAccount(emsAccount);
    emsAccount = undefined;
  }
  if (physicianAccount) {
    await deleteAccount(physicianAccount);
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
  // The reload-survival check and the completed-transport check at the end
  // both add real time on top of this already-substantial test (see
  // playwright.config.mts's 60s default).
  test.setTimeout(150000);

  // Grant geolocation explicitly scoped to the EMS origin. A permission
  // granted via `test.use({ permissions: [...] })` at context-creation time
  // does not reliably carry over once the page navigates to a *different*
  // origin later in the test — this is the more explicit, origin-scoped form.
  await context.grantPermissions(['geolocation'], { origin: EMS_ORIGIN });

  // --- EMS side: upload a patient with live-tracking enabled ---
  emsAccount = await signUpAndOnboard(
    page,
    'ems-tracker',
    { firstName: 'E2E', lastName: 'Medic' },
    { origin: EMS_ORIGIN, role: 'ems', onAccountCreated: (a) => (emsAccount = a) },
  );
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

  // A destination hospital is required for PatientViewerComponent to
  // resolve a route/ETA below — "General Hospital" is the seeded test-org
  // hospital referenced elsewhere in this suite. force: true — an empty,
  // never-focused mat-select rests its floating label directly over the
  // trigger's click point (see selectMatOption in ems-e2e's
  // patient-upload.spec.ts for the same, already-established fix).
  await page.getByLabel('Destination Hospital').click({ force: true });
  await page.getByRole('option', { name: 'General Hospital', exact: true }).click();

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

  // Reassigned below, once the actual last real publish's server timestamp
  // is known, to be the baseline the staleness mocking further down uses —
  // see the comment there for why.
  let publishedAtMs = Date.now();
  await page.getByRole('button', { name: 'Upload Patient' }).click();
  await expect(page.locator('.submit-button__spinner')).toBeVisible();
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

  // The full publishEmsLocation -> Pub/Sub -> onEmsLocationEvent -> Firestore
  // chain can take longer than a flat wait accounts for, especially on a
  // cold Cloud Function start — poll rather than assuming 3s is enough,
  // matching the generous timeouts the physician-side checks below already
  // use for the same underlying round trip.
  await expect
    .poll(() => getEmsLocationUpdatedAtMs(createdPatientId as string), { timeout: 20000 })
    .not.toBeUndefined();
  const updatedAtBeforeReload = await getEmsLocationUpdatedAtMs(createdPatientId as string);

  // EmsTrackingService's tracking state (the recurring publish interval,
  // which patients are tracked) is otherwise pure in-memory, wiped by
  // anything that tears down the page — a mobile browser discarding a
  // backgrounded tab under memory pressure once the EMS phone's screen
  // locks mid-transport, an accidental refresh, a network blip. Reloading
  // here — while sitting on the EMS home route, not this patient's own
  // edit page, since resuming shouldn't depend on which route happens to
  // be open (see apps/ems's app.config.ts and its provideAppInitializer)
  // — and then confirming a *newer* publish lands on its own proves
  // tracking survives that with zero action from EMS.
  await page.reload();
  await expect(page).toHaveURL(`${EMS_ORIGIN}/`);

  // Real time for at least one more 15s publish interval to fire on its own.
  await page.waitForTimeout(20000);

  const updatedAtAfterReload = await getEmsLocationUpdatedAtMs(createdPatientId as string);
  expect(
    updatedAtAfterReload,
    'expected a newer publish to have landed after the reload, with no manual re-toggle',
  ).toBeGreaterThan(updatedAtBeforeReload as number);

  // The staleness mocking below assumes `publishedAtMs` is (close to) the
  // real timestamp of the *last* actual publish — true before this test
  // added a real reload+resume in the middle, but the reload/resume above
  // pushes the real last-publish timestamp meaningfully later than the
  // original upload. Re-baseline off the server timestamp just confirmed
  // above so `+15_000`/`+40_000` below still land where they're supposed
  // to relative to the actual last write, not the original one.
  publishedAtMs = updatedAtAfterReload as number;

  // --- Physician side: the same patient should show up as actively tracked ---
  physicianAccount = await signUpAndOnboard(
    page,
    'physician-tracker',
    { firstName: 'E2E', lastName: 'Doctor' },
    {
      origin: PHYSICIAN_ORIGIN,
      role: 'physician',
      hospital: 'General Hospital',
      onAccountCreated: (a) => (physicianAccount = a),
    },
  );
  await expect(page).toHaveURL(`${PHYSICIAN_ORIGIN}/`);

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
  // The dot itself is always rendered now (online or offline) — the
  // `--active` modifier plus the "Tracking Online" label are what actually
  // signal tracking is live.
  await expect(card.locator('.patient-card__tracking-dot--active')).toBeVisible({ timeout: 30000 });
  await expect(card.locator('.patient-card__tracking-label--online')).toHaveText('Tracking Online');

  // Selecting the card into the viewer exercises PatientViewerComponent's
  // own live-position marker/indicator (ems-location.service.ts's
  // activeLocation()), a separate consumer of the same freshness signal
  // driving the card's dot above — confirms both stay in sync.
  await card.click();
  await expect(page.locator('.live-position-indicator')).toBeVisible();

  // Real Directions API call against the live deployed site (no mocking),
  // matching this spec's existing "hit the real backend" style — confirms
  // the route/ETA renders once both a live position and a destination
  // hospital (selected above) are available.
  await expect(page.locator('.route-info')).toBeVisible({ timeout: 15000 });

  // --- Mock further forward past STALE_AFTER_MS (35s, see ems-location.service.ts)
  // without waiting that long in real time, and confirm it goes stale.
  await mockElapsedTimeSincePublish(page, publishedAtMs, 40_000);

  await expect(card.locator('.patient-card__tracking-dot--active')).toHaveCount(0);
  await expect(card.locator('.patient-card__tracking-label--offline')).toHaveText('Tracking Offline');

  // The reload above resets MainViewComponent's in-memory `selectedPatient`,
  // so re-select the card to confirm the viewer's own indicator also honors
  // the same now-stale freshness signal, not just the list's dot.
  await card.click();
  await expect(page.locator('.live-position-indicator')).toHaveCount(0);
  await expect(page.locator('.route-info')).toHaveCount(0);

  // --- Reuse the same EMS session and patient one more time: complete the
  // transport, and confirm patient.service.ts's where('status','==','active')
  // removes it from this already-open physician session live, with no
  // reload — the same Firestore session (auth persists per-origin in this
  // one browser context) this test already established on the EMS side.
  await page.goto(EMS_ORIGIN);
  await expect(page).toHaveURL(`${EMS_ORIGIN}/`);
  await expect(emsCard).toBeVisible({ timeout: 15000 });

  await emsCard.getByRole('button', { name: 'Complete Transport' }).click();
  await page.locator('mat-dialog-container').getByRole('button', { name: 'Complete Transport' }).click();
  await expect(page.locator('.patient-summary-card', { hasText: patientName })).toHaveCount(0);

  await page.goto(PHYSICIAN_ORIGIN);
  await expect(page).toHaveURL(`${PHYSICIAN_ORIGIN}/`);
  await expect(card).toHaveCount(0, { timeout: 15000 });
});
