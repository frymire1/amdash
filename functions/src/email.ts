import { defineSecret } from 'firebase-functions/params';
import { logger } from 'firebase-functions/v2';
import { Resend } from 'resend';
import { AssignableRole } from './classes/assignable-role';

export const RESEND_API_KEY = defineSecret('RESEND_API_KEY');

// amdashtracking.com is verified in Resend's dashboard (Domains -> Add
// Domain -> DNS records added at the registrar) — this can now deliver to
// arbitrary recipients, not just the Resend account's own signup address
// the way the old onboarding@resend.dev sandbox sender was restricted to.
const FROM_ADDRESS = 'AmDash <noreply@amdashtracking.com>';

// ems -> the EMS app; physician/nurse -> the physician app (nurses use the
// same app as physicians, see physician/lib/router.dart's requiredRoles).
// Mirrors the Dart-side AppUrls class
// (flutter/packages/amdash_core/lib/src/app_urls.dart) — not worth a
// shared file for 2 entries on the functions side.
function loginUrlForRole(role: AssignableRole): string {
  return role === 'ems' ? 'https://amdash-ems-dev.web.app' : 'https://amdash-physician-dev.web.app';
}

// Email clients can't load local/repo files, so the logo has to be a
// publicly reachable URL — reusing the mark already deployed as the
// marketing site's apple-touch-icon.png (the same finalized Arctic Cyan
// mark used for the app icons/splash screens) rather than duplicating the
// image or setting up a separate CDN asset just for email. marketing has
// migrated from Firebase Hosting to Cloud Run (default *.run.app URL,
// confirmed live including this exact asset before this URL was updated).
const LOGO_URL = 'https://marketing-web-577422583971.northamerica-northeast2.run.app/apple-touch-icon.png';

// Email HTML has to be written for the lowest common denominator of
// rendering engines (Outlook's is Word's, not a browser's) — table-based
// layout and fully inline styles only, no external/`<style>`-block CSS,
// no flexbox/grid. Shared by all three transactional emails below: the
// header/card chrome (emailShell) and the teal CTA button (ctaButton) are
// identical across them, only the body copy and link differ.
function emailShell(bodyHtml: string): string {
  return `
    <!DOCTYPE html>
    <html>
      <body style="margin:0;padding:0;background-color:#EAF6F7;font-family:Arial,Helvetica,sans-serif;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background-color:#EAF6F7;padding:32px 16px;">
          <tr>
            <td align="center">
              <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="max-width:480px;width:100%;background-color:#ffffff;border-radius:12px;overflow:hidden;">
                <tr>
                  <td align="center" style="background-color:#071618;padding:32px 24px;">
                    <img src="${LOGO_URL}" width="56" height="56" alt="AmDash" style="display:block;border-radius:12px;" />
                    <div style="color:#ffffff;font-size:20px;font-weight:700;letter-spacing:0.5px;margin-top:12px;">AmDash</div>
                  </td>
                </tr>
                <tr>
                  <td style="padding:32px 24px;color:#0F201E;font-size:15px;line-height:1.6;">
                    ${bodyHtml}
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
  `;
}

function ctaButton(url: string, label: string): string {
  return `
    <table role="presentation" cellpadding="0" cellspacing="0">
      <tr>
        <td align="center" style="border-radius:8px;background-color:#12A7B5;">
          <a href="${url}" style="display:inline-block;padding:12px 28px;color:#ffffff;font-weight:600;text-decoration:none;font-size:15px;">${label}</a>
        </td>
      </tr>
    </table>
  `;
}

function welcomeEmailHtml({ email, firstName, loginUrl }: { email: string; firstName: string; loginUrl: string }): string {
  return emailShell(`
    <p style="margin:0 0 16px;">Hi ${firstName},</p>
    <p style="margin:0 0 24px;">An administrator has created an AmDash account for you at <strong>${email}</strong>.</p>
    ${ctaButton(loginUrl, 'Sign in to get started')}
    <p style="margin:24px 0 0;font-size:13px;color:#5E7A7D;">Since this is your first time signing in, you'll be asked to set a password after entering your email.</p>
  `);
}

function resetPasswordEmailHtml({ firstName, resetUrl }: { firstName: string; resetUrl: string }): string {
  return emailShell(`
    <p style="margin:0 0 16px;">Hi ${firstName},</p>
    <p style="margin:0 0 24px;">We got a request to reset the password for your AmDash account. If this was you, click below to choose a new one.</p>
    ${ctaButton(resetUrl, 'Reset your password')}
    <p style="margin:24px 0 0;font-size:13px;color:#5E7A7D;">This link will expire soon and can only be used once. If you didn't request this, you can safely ignore this email — your password won't be changed.</p>
  `);
}

function verifyEmailHtml({ firstName, verifyUrl }: { firstName: string; verifyUrl: string }): string {
  return emailShell(`
    <p style="margin:0 0 16px;">Hi ${firstName},</p>
    <p style="margin:0 0 24px;">Please verify your email address to finish setting up two-factor authentication for your AmDash account.</p>
    ${ctaButton(verifyUrl, 'Verify email address')}
  `);
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
      html: welcomeEmailHtml({ email, firstName, loginUrl }),
    });
    if (error) {
      logger.error('Failed to send welcome email', { email, error });
    }
  } catch (error) {
    logger.error('Failed to send welcome email', { email, error });
  }
}

// Unlike sendWelcomeEmail, this does NOT swallow a failed send: there's no
// fallback way for someone to get a reset link if this email never
// arrives, so a Resend failure here is thrown back to the caller (surfaces
// to the client as a real error) rather than logged-and-forgotten.
export async function sendPasswordResetEmail({
  email,
  firstName,
  resetUrl,
}: {
  email: string;
  firstName: string;
  resetUrl: string;
}): Promise<void> {
  const resend = new Resend(RESEND_API_KEY.value());
  const { error } = await resend.emails.send({
    from: FROM_ADDRESS,
    to: email,
    subject: 'Reset your AmDash password',
    html: resetPasswordEmailHtml({ firstName, resetUrl }),
  });
  if (error) {
    logger.error('Failed to send password reset email', { email, error });
    throw new Error('Failed to send the password reset email.');
  }
}

// See sendPasswordResetEmail's comment on why this throws rather than
// swallowing — this is the whole point of the call, not a side effect of
// something else that already succeeded.
export async function sendVerificationEmail({
  email,
  firstName,
  verifyUrl,
}: {
  email: string;
  firstName: string;
  verifyUrl: string;
}): Promise<void> {
  const resend = new Resend(RESEND_API_KEY.value());
  const { error } = await resend.emails.send({
    from: FROM_ADDRESS,
    to: email,
    subject: 'Verify your email for AmDash',
    html: verifyEmailHtml({ firstName, verifyUrl }),
  });
  if (error) {
    logger.error('Failed to send verification email', { email, error });
    throw new Error('Failed to send the verification email.');
  }
}
