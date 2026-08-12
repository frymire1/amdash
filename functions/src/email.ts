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

// Email clients can't load local/repo files, so the logo has to be a
// publicly reachable URL — reusing the mark already deployed as the
// marketing site's apple-touch-icon.png (the same finalized Arctic Cyan
// mark used for the app icons/splash screens) rather than duplicating the
// image or setting up a separate CDN asset just for email.
const LOGO_URL = 'https://amdash-marketing-dev.web.app/apple-touch-icon.png';

// Email HTML has to be written for the lowest common denominator of
// rendering engines (Outlook's is Word's, not a browser's) — table-based
// layout and fully inline styles only, no external/`<style>`-block CSS,
// no flexbox/grid. Kept as one template function (not a separate file)
// since this is the only transactional email this app sends so far.
function welcomeEmailHtml({ email, firstName, loginUrl }: { email: string; firstName: string; loginUrl: string }): string {
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
                    <p style="margin:0 0 16px;">Hi ${firstName},</p>
                    <p style="margin:0 0 24px;">An administrator has created an AmDash account for you at <strong>${email}</strong>.</p>
                    <table role="presentation" cellpadding="0" cellspacing="0">
                      <tr>
                        <td align="center" style="border-radius:8px;background-color:#12A7B5;">
                          <a href="${loginUrl}" style="display:inline-block;padding:12px 28px;color:#ffffff;font-weight:600;text-decoration:none;font-size:15px;">Sign in to get started</a>
                        </td>
                      </tr>
                    </table>
                    <p style="margin:24px 0 0;font-size:13px;color:#5E7A7D;">Since this is your first time signing in, you'll be asked to set a password after entering your email.</p>
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
