import { defineSecret } from 'firebase-functions/params';
import { logger } from 'firebase-functions/v2';
import { Resend } from 'resend';
import { AssignableRole } from './classes/assignable-role';

export const RESEND_API_KEY = defineSecret('RESEND_API_KEY');

// NOTE: gmail.com isn't a domain you can verify ownership of in Resend
// (Google owns it), so sends from this address will likely be rejected by
// Resend outright, or at best flagged as spoofed by SPF/DKIM/DMARC checks
// on the receiving end. Swap for a verified custom domain's address once
// one's set up in the Resend dashboard (Domains -> Add Domain -> add the
// DNS records shown), or use Resend's shared sandbox sender
// ('AmDash <onboarding@resend.dev>') for zero-setup testing in the
// meantime.
const FROM_ADDRESS = 'AmDash <frymire1@gmail.com>';

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
    await resend.emails.send({
      from: FROM_ADDRESS,
      to: email,
      subject: 'Your AmDash account is ready',
      html: `
        <p>Hi ${firstName},</p>
        <p>An administrator has created an AmDash account for you at <strong>${email}</strong>.</p>
        <p><a href="${loginUrl}">Sign in to get started</a> — since this is your first time signing in, you'll be asked to set a password after entering your email.</p>
      `,
    });
  } catch (error) {
    logger.error('Failed to send welcome email', { email, error });
  }
}
