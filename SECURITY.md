# Security

Infrastructure and request-layer hardening for AmDash — which Google/Firebase
products are in use and their HIPAA BAA-covered status, how data is
protected in transit and at rest, authentication/authorization controls,
audit logging, and what's planned next. Mirrors `TESTING.md`'s own "audit
trail" framing (see its Regulatory note), but for this instead of test
coverage.

## Google/Firebase products in use, and their HIPAA BAA status

**No BAA is currently in place, at all, for any product — see the note at
the end of this section for why.** Google publishes a specific list of
"covered products" its Business Associate Agreement (BAA) actually applies
to — using an *uncovered* product for PHI is a real HIPAA violation
regardless of Google's general security posture, so the "covered?" column
below is the load-bearing reference for that boundary. But covered-product
eligibility and an actually-executed BAA are two different things: **every
row in this table describes what would be true if AmDash had a signed BAA,
not AmDash's actual current legal HIPAA status, which is "no BAA, no HIPAA
protection from Google, regardless of which products are in use."** Sourced
by fetching Google's current covered-products list live rather than relying
on possibly-stale prior knowledge; re-verify against
[cloud.google.com/terms/service-terms](https://cloud.google.com/terms/service-terms)
before trusting an old copy of this file.

| Product | HIPAA covered? | PHI touches it? |
|---|---|---|
| Identity Platform | Yes (**confirmed active**) | Yes — auth records (email, uid) |
| ~~Firebase Authentication~~ (plain) | **No** | superseded — see below |
| Cloud Firestore | Yes | Yes — patient records, vitals, location |
| Cloud KMS | Yes | Indirectly — wraps the encryption keys protecting PII fields (never sees plaintext) |
| Cloud Functions (2nd gen, on Cloud Run) | Yes | Yes — all callables/triggers |
| Cloud Run (web hosting) | Yes | No — serves the app shell only, no PHI in the container |
| Firebase App Check | No | No — attestation tokens carry no patient data, by construction |
| Firebase Cloud Messaging | No | No — `functions/src/physician.ts`'s push payloads deliberately exclude patient-identifying fields for exactly this reason |
| Resend (email delivery) | N/A (not a Google product) | No — transactional emails (password reset, welcome) carry no PHI |

**Plain Firebase Authentication is not on Google's covered-products list —
Identity Platform is.** They're the same underlying service; upgrading is a
one-click Firebase Console action (Authentication → Settings → "Upgrade to
Identity Platform") with zero code changes to any `AuthService` method, and
the free tier (50,000 MAU) comfortably covers AmDash's actual usage.

**Confirmed currently active** (verified 2026-08-31 via a live Firebase
Console screenshot — the Authentication page reads "Authentication with
Identity Platform" rather than showing the upgrade prompt). The exact date
this was actually turned on isn't known — it may well predate this file —
so treat 2026-08-31 as "confirmed no later than," not "upgraded on." This
was a manual console step either way, done outside of source control, so
there's no commit/PR to point to for exactly when it happened.

Enabling the product is necessary but not sufficient for actual HIPAA
protection on its own — it only matters paired with an accepted Business
Associate Amendment (BAA), a separate step done by a super-admin in the
**Google Admin console** (admin.google.com, not Firebase/Cloud Console):
Account → Account settings → Legal and compliance → Security and Privacy
Additional Terms → accept the HIPAA BAA.

**Blocked, not just pending: AmDash has no legal business entity yet.** A
BAA is a legal contract between two parties — Google and a HIPAA-regulated
"covered entity" or "business associate" — and there is currently nothing
on AmDash's side capable of being a party to that contract. This isn't an
engineering task or a console setting; it needs incorporation (and
whatever entity structure a lawyer recommends for a healthcare-adjacent
product) to happen first. Every "HIPAA covered" designation in the table
above is describing product *eligibility*, not AmDash's actual legal
status today — treat it that way in any conversation with an auditor,
investor, or customer: **the honest current answer to "is AmDash HIPAA
compliant" is no, pending incorporation and a signed BAA, not "yes" or
"almost."** Update this note the moment that changes.

App Check and FCM being uncovered is fine specifically *because* neither
ever carries PHI — the same reasoning already applied deliberately elsewhere
in this codebase (see `physician.ts`'s comment on its own push payloads). If
that invariant ever changes for either product, this row needs re-evaluating
before shipping.

## Encryption in transit

Every request this system makes or receives — Flutter client to Cloud
Functions/Firestore/Identity Platform, and browser to the Cloud Run-hosted
web apps — is HTTPS-only; there is no plaintext HTTP path anywhere in the
stack (Cloud Run rejects non-TLS traffic by default, and every Firebase
client SDK talks HTTPS/gRPC-over-TLS unconditionally, not as an opt-in
setting).

TLS termination for all of it happens at Google's own edge — **Google Front
End (GFE)**, the same termination point in front of every public Google
Cloud/Firebase service (Cloud Run, Cloud Functions, Firestore, Identity
Platform). GFE negotiates the strongest protocol both sides support and has
had **TLS 1.3 on by default since 2020** ("TLS 1.3 is now on by default for
Google Cloud services," Google Cloud blog); the TLS implementation itself is
BoringSSL, whose cryptographic core (BoringCrypto) is FIPS 140-3 Level 1
validated. None of this is configuration AmDash owns or could accidentally
weaken — it's the platform default for every one of the covered products
above.

## Encryption at rest

**Baseline (every record, no configuration):** Firestore and Cloud Storage
both encrypt all data at rest by default, transparently, using Google-owned
and -rotated keys — this needs no setup and can't be disabled. This is the
floor every organization's data gets regardless of any setting in AmDash
itself.

**Above the baseline, opt-in per organization — Customer-Managed Encryption
Keys (CMEK) for Canadian data residency.** An organization can request this
(`cmekRequested` flag, set via `setOrganizationCmekPreference` in
`functions/src/admin.ts`) to get field-level envelope encryption on its
patients' two most sensitive fields — `name` and `healthcareNumber` — on top
of Firestore's own baseline encryption:

- **One Cloud KMS `CryptoKey` per organization** (`functions/src/kms.ts`'s
  `getOrCreateOrgKey`), region-pinned to `northamerica-northeast2` (Toronto)
  — not a single shared key across every org. This buys two things a shared
  key doesn't: a distinct Cloud KMS audit trail per organization, and clean
  crypto-shredding (destroying one org's key makes every document encrypted
  under it permanently unrecoverable, a direct answer to a future "delete
  this org's PII" request without hunting down every Firestore document).
- **Automatic 90-day key rotation** — Cloud KMS's `Decrypt` API
  auto-detects which key version wrapped a given ciphertext, so rotation
  needs no companion rewrap job; old ciphertext keeps decrypting forever.
- **Envelope encryption**: each encrypted field gets its own random
  AES-256-GCM Data Encryption Key (DEK), generated fresh per write. The
  field's actual plaintext is encrypted locally with that DEK; only the
  small DEK itself — never the plaintext PII — is sent to Cloud KMS to be
  wrapped by the org's key. This is the standard pattern for exactly the
  reason it exists here: it decouples the field-encryption algorithm from
  key management, and it means raw patient PII never crosses the KMS API
  boundary at all, only an opaque 32-byte key does.
- The stored blob (`EncryptedField` in `kms.ts`) is self-contained — it
  carries its own `keyName`, wrapped DEK, IV, and GCM auth tag, so
  decrypting never needs a separate lookup back to the organization.
  `firestore.rules`' `fieldsRespectCmek` check additionally makes it
  structurally impossible for a client (even a buggy or bypassed EMS app)
  to write a plaintext `name`/`healthcareNumber` for a CMEK-opted-in
  organization — the shape check happens at the security-rules layer, not
  just in application code.
- Decryption is gated behind the `patient.decrypt` audit action (see below)
  and the `decryptPatientFields`/related callables' own role checks — not
  every signed-in user who can read a patient document can decrypt these
  two fields.

This is opt-in, not universal, because it's specifically the mechanism for
organizations that have a Canadian-data-residency requirement beyond
Firestore's own baseline encryption — every organization gets the baseline
regardless of this toggle.

## Authentication & authorization

- **Identity Platform** (see the covered-products table above) — the actual
  BAA-covered identity layer once the console upgrade is done.
- **Mandatory MFA, account-wide.** `AppRouteGuard` (in
  `amdash_core/lib/src/guards/app_guards.dart`) defaults `requireMfa: true`
  and redirects any signed-in user with zero enrolled second factors
  straight to a mandatory TOTP enrollment screen before they can reach
  *any* other route — this isn't a per-app or opt-in setting; it's enforced
  once, in the shared guard every app's router uses. MFA state itself
  (`mfaEnrolledFactorsProvider`) is account-wide, not app-specific — one
  enrollment covers a user across every AmDash app they have access to.
- **Server-side password complexity enforcement** — see "Login form
  hardening" below.
- **Firestore Security Rules enforce org isolation and role-based access**
  on every collection (`firestore.rules`) — a signed-in user can only read
  data belonging to their own `organizationId` (or is a super-admin), and
  writes to sensitive collections (`patients`, `hospitals`, `organizations`,
  `auditLog`, the new `_rateLimits`) are blocked from direct client access
  entirely, routed instead through Cloud Functions using the Admin SDK
  (which independently re-checks role/org before doing anything). This is
  defense in depth on top of Cloud Functions' own `getCallerProfile`-based
  role checks, not a substitute for them — both layers independently
  enforce the same boundary.

## Audit logging

Every sensitive patient action — create, update, complete, delete, decrypt
(the CMEK fields above), and FHIR export — is written to an append-only
`auditLog` Firestore collection (`functions/src/audit.ts`'s `logAudit`),
recording the actor's uid/email, the organization, the target, and a
server-generated timestamp. This collection has **no client read or write
access at all** (`firestore.rules`: `allow read, write: if false`) — the
only path in or out is server-side (`logAudit` itself for writes, the
`listAuditLog` callable, itself role-gated, for reads).

`patient.fhirExport` is logged at the same sensitivity tier as
`patient.decrypt` deliberately — a FHIR export is PHI leaving AmDash's own
encryption/access-control boundary entirely as a portable file, not merely
being viewed on-screen, and is treated that way in the audit trail.
User/hospital/organization governance actions (account creation, role
changes, hospital management, the organization-level audit-logging toggle
itself) are always logged regardless of any per-organization setting —
otherwise disabling that toggle could hide the very act of disabling it.

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
| `ems` | Play Integrity | App Attest (Device Check fallback) | reCAPTCHA Enterprise |
| `physician` | Play Integrity | App Attest (Device Check fallback) | reCAPTCHA Enterprise |
| `admin` | — (no native build) | — (no native build) | reCAPTCHA Enterprise |

Web uses reCAPTCHA *Enterprise*, not classic v3 — one shared key
(`APP_CHECK_RECAPTCHA_SITE_KEY`, passed as a `--dart-define` in
`deploy-web-cloud-run.yml`, not a repo secret since site/key IDs are meant to
be public and embedded in client code) registered against the three real
Cloud Run hostnames (`admin-web`/`physician-web`/`ems-web`). CI's own web e2e
builds don't pass it — they run on `localhost`, a domain the key was never
registered for, so it wouldn't validate there regardless, and an unverified
token is harmless in monitor mode.

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

A caller who's hit their limit gets a specific, friendly message in the
Flutter UI ("You've tried too many times. Please wait a while before trying
again.") rather than a generic error — `login_screen.dart` detects the
`resource-exhausted` error code the rate limiter throws and surfaces it
distinctly, so a legitimate user who's just moving fast isn't left thinking
something is broken.

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

- **The HIPAA BAA itself — blocked on incorporation, not an engineering
  task.** See the note in the covered-products section above. Until this
  is signed, none of this file's other hardening work makes AmDash
  actually HIPAA compliant, only closer to ready for the day it can be.
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
- **CMEK is opt-in, not the default for every organization** — an
  organization has to explicitly request Canadian data residency to get
  the field-level KMS envelope encryption described above; every
  organization still gets Firestore's own baseline at-rest encryption
  regardless.

## Regulatory note

Same caveat as `TESTING.md`'s own: this is engineering hardening, not a
compliance certification by itself. If AmDash goes through a HIPAA or
Canadian health-data audit, this file — plus the covered-products table
above, kept current — is meant to be the starting reference for that
conversation, not a substitute for it.
