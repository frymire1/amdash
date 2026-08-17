import { logger } from 'firebase-functions/v2';
import { FieldValue, getFirestore } from 'firebase-admin/firestore';
import { AuditAction } from './classes/audit-action';

// Extracted from admin.ts so patients.ts's Firestore triggers/callables (and
// any future domain file) can log to the same `auditLog` collection without
// admin.ts needing to export its internals — this module owns nothing but
// the write path itself.
//
// Best-effort — an audit log write failing shouldn't fail the mutation it
// was recording, same non-critical-notification rationale as
// sendWelcomeEmail in email.ts. No client ever reads/writes this collection
// directly (see firestore.rules); listAuditLog (admin.ts) is the only read
// path.
export async function logAudit(entry: {
  action: AuditAction;
  actor: { uid: string; email: string };
  organizationId: string | undefined;
  target?: string;
  details?: Record<string, unknown>;
}): Promise<void> {
  try {
    await getFirestore()
      .collection('auditLog')
      .add({
        action: entry.action,
        actorUid: entry.actor.uid,
        actorEmail: entry.actor.email,
        organizationId: entry.organizationId ?? null,
        target: entry.target ?? null,
        details: entry.details ?? null,
        timestamp: FieldValue.serverTimestamp(),
      });
  } catch (error) {
    logger.error('Failed to write audit log entry', { entry, error });
  }
}

// A pseudo-actor for entries logged by a scheduled job rather than a signed-
// in user — currently just cleanupCompletedPatients' retention deletes.
export const SYSTEM_ACTOR = { uid: 'system', email: 'Automated (retention policy)' };

// patients/{patientId} is written directly by the EMS client (see
// patient_upload_service.dart — kept that way for offline queueing; see
// patients.ts), so its Firestore-trigger-based audit entries (onPatientCreated/
// onPatientUpdated in patients.ts) can't rely on `request.auth` the way a
// callable can. Instead the client stamps `createdBy`/`updatedBy` (uids,
// enforced to match the writer by firestore.rules), and this resolves that
// uid to the email the audit log displays — same users/{uid} doc
// getCallerProfile (shared.ts) already reads, just without requiring a full
// profile fetch. Falls back to 'unknown' for a missing/deleted uid rather
// than throwing — a bad audit *label* shouldn't be possible, since these
// triggers have no mutation left to protect by failing loudly.
export async function resolveActor(uid: unknown): Promise<{ uid: string; email: string }> {
  if (typeof uid !== 'string' || !uid) return { uid: 'unknown', email: 'unknown' };
  try {
    const snapshot = await getFirestore().collection('users').doc(uid).get();
    const email = snapshot.data()?.['email'];
    return { uid, email: typeof email === 'string' && email ? email : 'unknown' };
  } catch {
    return { uid, email: 'unknown' };
  }
}
