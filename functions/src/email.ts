import { defineSecret } from 'firebase-functions/params';
import { logger } from 'firebase-functions/v2';
import { Resend } from 'resend';
import { AssignableRole } from './classes/assignable-role';

export const RESEND_API_KEY = defineSecret('RESEND_API_KEY');

// Resend's shared sandbox sender — works immediately with zero setup, but
// Resend restricts it to only deliver to the email address the Resend
// account itself was signed up with (an anti-abuse limit on the shared
// domain, not something this code can work around). So createUser's welcome
// email will only actually land when testing with that one address; any
// other new user's email will get the same silent-looking (now logged)
// rejection this sender was swapped in to fix. Swap for a verified custom
// domain's address once one's set up in the Resend dashboard (Domains ->
// Add Domain -> add the DNS records shown) to send to arbitrary recipients.
const FROM_ADDRESS = 'AmDash <onboarding@resend.dev>';

// ems -> the EMS app; physician/nurse -> the physician app (nurses use the
// same app as physicians, see physician/lib/router.dart's requiredRoles).
// Mirrors the Dart-side AppUrls class
// (flutter/packages/amdash_core/lib/src/app_urls.dart) — not worth a
// shared file for 2 entries on the functions side.
function loginUrlForRole(role: AssignableRole): string {
  return role === 'ems' ? 'https://amdash-ems-dev.web.app' : 'https://amdash-physician-dev.web.app';
}

// Called after createUser's Firestore write already succeeded — the
// account exists and is usable (via "Forgot password?") regardless of
// whether this email actually sends, so a Resend hiccup here is caught
// and logged rather than rethrown. Failing the whole createUser call over
// a non-critical notification would be a worse outcome than a user who
// has to be told about their account some other way.
export async function sendWelcomeEmail({
  email,
  firstName,
  role,
}: {
  email: string;
  firstName: string;
  role: AssignableRole;
}): Promise<void> {
  const resend = new Resend(RESEND_API_KEY.value());
  const loginUrl = loginUrlForRole(role);

  try {
    // The Resend SDK does NOT reject/throw on an API-level failure (e.g. a
    // rejected From address) — it resolves normally with `error` populated
    // instead, so that has to be checked explicitly or a failed send goes
    // completely unlogged.
    const { error } = await resend.emails.send({
      from: FROM_ADDRESS,
      to: email,
      subject: 'Your AmDash account is ready',
      html: `
        <p>Hi ${firstName},</p>
        <p>An administrator has created an AmDash account for you at <strong>${email}</strong>.</p>
        <p><a href="${loginUrl}">Sign in to get started</a> — since this is your first time signing in, you'll be asked to set a password after entering your email.</p>
      `,
    });
    if (error) {
      logger.error('Failed to send welcome email', { email, error });
    }
  } catch (error) {
    logger.error('Failed to send welcome email', { email, error });
  }
}
