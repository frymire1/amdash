# Security

Infrastructure and request-layer hardening for AmDash — which Google/Firebase
products are in use and their HIPAA BAA-covered status, the account-protection
layers currently in place, and what's planned next. Mirrors `TESTING.md`'s own
"audit trail" framing (see its Regulatory note), but for this instead of test
coverage.

## Google/Firebase products in use, and their HIPAA BAA status

Google publishes a specific list of "covered products" its Business
Associate Agreement (BAA) actually applies to — using an *uncovered* product
for PHI is a real HIPAA violation regardless of Google's general security
posture, so this table is the load-bearing reference for that boundary, not
a formality. Sourced by fetching Google's current list live rather than
relying on possibly-stale prior knowledge; re-verify against
[cloud.google.com/terms/service-terms](https://cloud.google.com/terms/service-terms)
before trusting an old copy of this file.

| Product | HIPAA covered? | PHI touches it? |
|---|---|---|
| Identity Platform | Yes | Yes — auth records (email, uid) |
| ~~Firebase Authentication~~ (plain) | **No** | superseded — see below |
| Cloud Firestore | Yes | Yes — patient records, vitals, location |
| Cloud Functions (2nd gen, on Cloud Run) | Yes | Yes — all callables/triggers |
| Cloud Run (web hosting) | Yes | No — serves the app shell only, no PHI in the container |
| Firebase App Check | No | No — attestation tokens carry no patient data, by construction |
| Firebase Cloud Messaging | No | No — `functions/src/physician.ts`'s push payloads deliberately exclude patient-identifying fields for exactly this reason |
| Resend (email delivery) | N/A (not a Google product) | No — transactional emails (password reset, welcome) carry no PHI |

**Plain Firebase Authentication is not on Google's covered-products list —
Identity Platform is.** They're the same underlying service; upgrading is a
one-click Firebase Console action (Authentication → Settings → "Upgrade to
Identity Platform") with zero code changes to any `AuthService` method, and
the free tier (50,000 MAU) comfortably covers AmDash's actual usage. **This
upgrade is a manual console step, done outside of source control — check the
Firebase Console directly for current status; this file only records that
it's required, not a live signal of whether it's happened yet.**

App Check and FCM being uncovered is fine specifically *because* neither
ever carries PHI — the same reasoning already applied deliberately elsewhere
in this codebase (see `physician.ts`'s comment on its own push payloads). If
that invariant ever changes for either product, this row needs re-evaluating
before shipping.

## Firebase App Check

Attests that a request genuinely comes from a real instance of this app
(caller *identity*), not a script or a reverse-engineered client hitting the
API directly. Independent of, and complementary to, the rate limiter below,
which checks caller *behavior* instead — a genuine, App-Check-verified
client can still be abusive.

**Status: wired into all three apps, monitor mode only.** Tokens are
attached to every request and logged server-side, but nothing is rejected
yet — that's a deliberate, separate later step (flipping enforcement per
service in the Firebase Console), gated on the App Check metrics dashboard
first showing real traffic is actually covered. Flipping enforcement before
confirming that would risk locking out real users, with no separate
dev/staging environment to catch the mistake first (this repo has a single
shared Firebase project — see `.firebaserc`).

Providers, matching each platform's Firebase-recommended option:

| App | Android | iOS | Web |
|---|---|---|---|
| `ems` | Play Integrity | App Attest (Device Check fallback) | reCAPTCHA v3 |
| `physician` | Play Integrity | App Attest (Device Check fallback) | reCAPTCHA v3 |
| `admin` | — (no native build) | — (no native build) | reCAPTCHA v3 |

Debug builds use the debug provider instead (`kDebugMode`-gated in each
app's `main.dart`), which needs a token registered by hand in Firebase
Console → App Check → (app) → Manage debug tokens. CI's Android e2e job
(`flutter-android-e2e` in `.github/workflows/ci.yml`) passes one through via
the `FIREBASE_APPCHECK_DEBUG_TOKEN` repo secret and a matching
`--dart-define`, so a debug-build Patrol run mints a real, registered token
instead of an unregistered ad-hoc one — this is groundwork for the day
enforcement flips, not something that changes behavior today (monitor mode
doesn't reject an unregistered token either way).

## Rate limiting

Three Cloud Functions callables have no `request.auth` to gate on at all —
they exist specifically to be called *before* sign-in — so each is
throttled directly, independent of App Check, via a Firestore-backed
fixed-window counter (`functions/src/rate-limit.ts`, keyed on a SHA-256 hash
of email/IP, never the raw value, under the `_rateLimits` collection —
denied to every client in `firestore.rules`, Admin SDK access only).

| Callable | Limits |
|---|---|
| `checkAccountStatus` | 20/hour per IP |
| `setInitialPassword` | 5/hour per IP, 5/hour per target email |
| `requestPasswordReset` | 20/hour per IP, 3/hour per target email (the tighter of the two — this is the inbox-bombing vector) |

## Login form hardening

Client-side email format validation and a password-complexity checklist in
`login_screen.dart` are UX guidance only — the actual enforcement boundary
is server-side, since every callable above is reachable directly (bypassing
the Flutter UI entirely). `setInitialPassword` independently re-checks the
same complexity rules (`functions/src/auth.ts`'s
`passwordMeetsComplexityRequirements` — min 8 characters, an uppercase
letter, a number, a special character) before ever touching an account.

`requestPasswordReset` ("Forgot password?") always returns the same
generic `{ email }` response whether or not the account exists, and does no
work (no link minted, no email sent) for one that doesn't — fixed from an
earlier version that threw a distinguishing error for an unregistered
address, a textbook account-enumeration side channel.

## Explicitly not done yet

- **App Check enforcement** — still monitor mode everywhere (see above);
  flipping it per-service is a deliberate future step once the metrics
  dashboard confirms real traffic is covered.
- **Cloud Armor + a Load Balancer in front of Cloud Run** — Cloud Armor
  attaches to a Load Balancer, not to Cloud Run directly, and no Load
  Balancer exists today (the 4 web apps are hit directly via their
  `*.run.app` URLs). Standing this up — new billed resource, DNS cutover,
  no Terraform/IaC in this repo yet to automate it — is a separate,
  multi-day infrastructure project, scoped out of this pass on purpose
  rather than rushed alongside it.

## Regulatory note

Same caveat as `TESTING.md`'s own: this is engineering hardening, not a
compliance certification by itself. If AmDash goes through a HIPAA or
Canadian health-data audit, this file — plus the covered-products table
above, kept current — is meant to be the starting reference for that
conversation, not a substitute for it.
