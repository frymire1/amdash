import { beforeEach, describe, expect, it, vi } from 'vitest';

// vi.hoisted() is required (not plain top-level consts) — vi.mock()
// factories are hoisted above every other statement in the file. See
// audit.test.ts's identical comment for the full explanation.
const { mockSend, mockLoggerError } = vi.hoisted(() => ({
  mockSend: vi.fn(),
  mockLoggerError: vi.fn(),
}));

vi.mock('resend', () => ({
  Resend: vi.fn(function (this: Record<string, unknown>) {
    this['emails'] = { send: mockSend };
  }),
}));

vi.mock('firebase-functions/v2', () => ({
  logger: { error: mockLoggerError },
}));

vi.mock('firebase-functions/params', () => ({
  defineSecret: () => ({ value: () => 'fake-resend-api-key' }),
}));

import { sendPasswordResetEmail, sendVerificationEmail, sendWelcomeEmail } from './email';

describe('sendWelcomeEmail', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    mockSend.mockResolvedValue({ error: null });
  });

  it('sends from the AmDash address with the right recipient/subject', async () => {
    await sendWelcomeEmail({ email: 'new-user@example.com', firstName: 'Jordan', role: 'ems' });

    expect(mockSend).toHaveBeenCalledWith(
      expect.objectContaining({
        from: 'AmDash <noreply@amdashtracking.com>',
        to: 'new-user@example.com',
        subject: 'Your AmDash account is ready',
      }),
    );
  });

  it('points an EMS account at the EMS app login URL', async () => {
    await sendWelcomeEmail({ email: 'a@example.com', firstName: 'Jordan', role: 'ems' });
    const html = mockSend.mock.calls[0][0].html as string;
    expect(html).toContain('https://amdash-ems-dev.web.app');
  });

  it('points a physician or nurse account at the physician app login URL', async () => {
    await sendWelcomeEmail({ email: 'a@example.com', firstName: 'Jordan', role: 'physician' });
    expect((mockSend.mock.calls[0][0].html as string)).toContain('https://amdash-physician-dev.web.app');

    mockSend.mockClear();
    await sendWelcomeEmail({ email: 'a@example.com', firstName: 'Jordan', role: 'nurse' });
    expect((mockSend.mock.calls[0][0].html as string)).toContain('https://amdash-physician-dev.web.app');
  });

  it('is best-effort: logs and does not throw when Resend reports an API-level error', async () => {
    mockSend.mockResolvedValue({ error: { message: 'domain not verified' } });

    await expect(sendWelcomeEmail({ email: 'a@example.com', firstName: 'J', role: 'ems' })).resolves.toBeUndefined();
    expect(mockLoggerError).toHaveBeenCalledWith('Failed to send welcome email', expect.any(Object));
  });

  it('is best-effort: logs and does not throw when the Resend call itself throws', async () => {
    mockSend.mockRejectedValue(new Error('network error'));

    await expect(sendWelcomeEmail({ email: 'a@example.com', firstName: 'J', role: 'ems' })).resolves.toBeUndefined();
    expect(mockLoggerError).toHaveBeenCalledWith('Failed to send welcome email', expect.any(Object));
  });
});

describe('sendPasswordResetEmail', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    mockSend.mockResolvedValue({ error: null });
  });

  it('sends the reset link and subject to the right recipient', async () => {
    await sendPasswordResetEmail({ email: 'user@example.com', firstName: 'Jordan', resetUrl: 'https://reset.link' });

    expect(mockSend).toHaveBeenCalledWith(
      expect.objectContaining({ to: 'user@example.com', subject: 'Reset your AmDash password' }),
    );
    expect((mockSend.mock.calls[0][0].html as string)).toContain('https://reset.link');
  });

  it('throws (unlike the welcome email) when Resend reports an error — there is no fallback delivery path', async () => {
    mockSend.mockResolvedValue({ error: { message: 'bounced' } });

    await expect(
      sendPasswordResetEmail({ email: 'a@example.com', firstName: 'J', resetUrl: 'https://reset.link' }),
    ).rejects.toThrow('Failed to send the password reset email.');
    expect(mockLoggerError).toHaveBeenCalled();
  });
});

describe('sendVerificationEmail', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    mockSend.mockResolvedValue({ error: null });
  });

  it('sends the verification link and subject to the right recipient', async () => {
    await sendVerificationEmail({ email: 'user@example.com', firstName: 'Jordan', verifyUrl: 'https://verify.link' });

    expect(mockSend).toHaveBeenCalledWith(
      expect.objectContaining({ to: 'user@example.com', subject: 'Verify your email for AmDash' }),
    );
    expect((mockSend.mock.calls[0][0].html as string)).toContain('https://verify.link');
  });

  it('throws when Resend reports an error', async () => {
    mockSend.mockResolvedValue({ error: { message: 'bounced' } });

    await expect(
      sendVerificationEmail({ email: 'a@example.com', firstName: 'J', verifyUrl: 'https://verify.link' }),
    ).rejects.toThrow('Failed to send the verification email.');
  });
});
