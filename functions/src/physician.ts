import { onDocumentCreated } from 'firebase-functions/v2/firestore';
import { getMessaging } from 'firebase-admin/messaging';
import { FieldValue, Timestamp, getFirestore } from 'firebase-admin/firestore';
import { REGION } from './shared';

// Fires whenever EMS uploads a new patient. Detection lives entirely here,
// server-side, rather than client-side Firestore watching — that's what
// makes delivery work even if a physician's tab (or browser) isn't open,
// which a client-side listener could never do.
export const sendNewPatientAlerts = onDocumentCreated({ document: 'patients/{patientId}', region: REGION }, async (event) => {
  const patient = event.data?.data();
  if (!patient?.['organizationId'] || !patient?.['destination']) {
    return;
  }

  const matching = await getFirestore()
    .collection('users')
    .where('organizationId', '==', patient['organizationId'])
    .where('workLocation', '==', patient['destination'])
    .where('newPatientAlertsExpiresAt', '>', Timestamp.now())
    .get();

  const tokensByUser = matching.docs.map((userDoc) => ({
    ref: userDoc.ref,
    tokens: (userDoc.data()['fcmTokens'] as string[] | undefined) ?? [],
  }));
  const allTokens = tokensByUser.flatMap((user) => user.tokens);
  if (allTokens.length === 0) {
    return;
  }

  const response = await getMessaging().sendEachForMulticast({
    tokens: allTokens,
    data: {
      title: 'New patient inbound',
      body: typeof patient['name'] === 'string' && patient['name'] ? patient['name'] : 'A new patient has been uploaded.',
    },
  });

  if (response.failureCount > 0) {
    response.responses.forEach((result, index) => {
      if (!result.success) {
        console.error(`sendNewPatientAlerts: token ${index} failed`, result.error?.code, result.error?.message);
      }
    });
  }

  // A token FCM reports as unregistered/invalid is permanently dead — prune
  // it from whichever user doc(s) held it so it doesn't keep silently
  // failing on every future patient.
  const deadTokens = new Set(
    response.responses
      .map((result, index) => (!result.success && isUnregisteredError(result.error) ? allTokens[index] : undefined))
      .filter((token): token is string => !!token),
  );
  if (deadTokens.size === 0) {
    return;
  }

  await Promise.all(
    tokensByUser
      .filter((user) => user.tokens.some((token) => deadTokens.has(token)))
      .map((user) => user.ref.update({ fcmTokens: FieldValue.arrayRemove(...user.tokens.filter((token) => deadTokens.has(token))) })),
  );
});

function isUnregisteredError(error: { code?: string } | undefined): boolean {
  return error?.code === 'messaging/registration-token-not-registered';
}
