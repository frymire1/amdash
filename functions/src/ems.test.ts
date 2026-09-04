import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fakeCallableRequest, fakeDocumentEvent } from './test-utils';

// vi.hoisted() is required (not plain top-level consts) — see
// audit.test.ts's comment for why.
const {
  mockPatientGet,
  mockCollection,
  mockRecursiveDelete,
  mockGetCallerProfile,
  mockPublishMessage,
  mockTopic,
  mockLocationSet,
  mockLocationGet,
  mockPatientLocationRef,
  mockHospitalsWhere1,
  mockHospitalsWhere2,
  mockHospitalsLimit,
  mockHospitalsGet,
  mockPatientsWhere,
  mockPatientsActiveGet,
  mockUsersGet,
  mockNotifyPatientProximity,
  mockSendAlertPush,
  mockLoggerError,
} = vi.hoisted(() => {
  const mockPublishMessage = vi.fn();
  const mockPatientGet = vi.fn();
  const mockLocationSet = vi.fn();
  const mockLocationGet = vi.fn();

  const mockHospitalsGet = vi.fn();
  const mockHospitalsLimit = vi.fn(() => ({ get: mockHospitalsGet }));
  const mockHospitalsWhere2 = vi.fn(() => ({ limit: mockHospitalsLimit }));
  const mockHospitalsWhere1 = vi.fn(() => ({ where: mockHospitalsWhere2 }));

  const mockPatientsActiveGet = vi.fn();
  const mockPatientsWhere = vi.fn(() => ({ get: mockPatientsActiveGet }));
  const mockUsersGet = vi.fn();

  return {
    mockPatientGet,
    mockCollection: vi.fn((name: string) => {
      if (name === 'patients') return { doc: (id: string) => ({ get: mockPatientGet, id }), where: mockPatientsWhere };
      if (name === 'hospitals') return { where: mockHospitalsWhere1 };
      if (name === 'users') return { doc: (id: string) => ({ get: mockUsersGet, id, ref: `USER_REF_${id}` }) };
      throw new Error(`Unexpected collection in test: ${name}`);
    }),
    mockRecursiveDelete: vi.fn(),
    mockGetCallerProfile: vi.fn(),
    mockPublishMessage,
    mockTopic: vi.fn(() => ({ publishMessage: mockPublishMessage })),
    mockLocationSet,
    mockLocationGet,
    mockPatientLocationRef: vi.fn(() => ({ set: mockLocationSet, get: mockLocationGet })),
    mockHospitalsWhere1,
    mockHospitalsWhere2,
    mockHospitalsLimit,
    mockHospitalsGet,
    mockPatientsWhere,
    mockPatientsActiveGet,
    mockUsersGet,
    mockNotifyPatientProximity: vi.fn(),
    mockSendAlertPush: vi.fn(),
    mockLoggerError: vi.fn(),
  };
});

vi.mock('@google-cloud/pubsub', () => ({
  PubSub: vi.fn(function (this: Record<string, unknown>) {
    this['topic'] = mockTopic;
  }),
}));

vi.mock('firebase-admin/firestore', () => ({
  getFirestore: () => ({ collection: mockCollection, recursiveDelete: mockRecursiveDelete }),
  FieldValue: {
    serverTimestamp: () => 'SERVER_TIMESTAMP',
    arrayUnion: (...items: number[]) => ({ __arrayUnion: items }),
    delete: () => 'FIELD_DELETED',
  },
}));

vi.mock('firebase-functions/v2', () => ({
  logger: { error: mockLoggerError },
}));

vi.mock('firebase-functions/params', () => ({
  defineSecret: () => ({ value: () => 'fake-directions-api-key' }),
}));

vi.mock('./auth', () => ({
  REGION: 'northamerica-northeast2',
  getCallerProfile: mockGetCallerProfile,
}));

vi.mock('./patient-data', () => ({
  patientLocationRef: mockPatientLocationRef,
}));

vi.mock('./physician', () => ({
  notifyPatientProximity: mockNotifyPatientProximity,
  sendAlertPush: mockSendAlertPush,
}));

import { checkEmsConnectivity, onEmsLocationEvent, onPatientDeleted, publishEmsLocation, stopEmsLocation } from './ems';

const EMS_PROFILE = { uid: 'ems-uid', email: 'ems@example.com', role: ['ems'], organizationId: 'org-1' };

function activeLocationEvent(overrides: Record<string, unknown> = {}) {
  return {
    data: {
      message: {
        json: { patientId: 'p1', organizationId: 'org-1', active: true, latitude: 43.6, longitude: -79.4, ...overrides },
      },
    },
  } as never;
}

function okDirectionsResponse(durationSeconds: number) {
  return {
    json: () =>
      Promise.resolve({
        status: 'OK',
        routes: [
          {
            legs: [{ duration: { text: 'n/a', value: durationSeconds }, distance: { text: 'n/a', value: 1 } }],
            overview_polyline: { points: 'AA' },
          },
        ],
      }),
  };
}

beforeEach(() => {
  vi.resetAllMocks();
  vi.unstubAllGlobals();
  // Default: no prior location doc, no prior patient doc — most tests
  // below that don't care about proximity-check specifics never even
  // reach the patient-lookup guard, since an empty patient doc short-
  // circuits checkProximityAlertThresholds immediately (see its own
  // organizationId/destination guard).
  mockLocationGet.mockResolvedValue({ data: () => undefined });
  mockPatientGet.mockResolvedValue({ data: () => undefined });
  mockUsersGet.mockResolvedValue({ exists: false, data: () => undefined });
  mockPatientsActiveGet.mockResolvedValue({ docs: [] });
});

describe('publishEmsLocation', () => {
  it('throws permission-denied for a non-EMS caller', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'] });
    await expect(
      publishEmsLocation.run(fakeCallableRequest({ patientId: 'p1', latitude: 1, longitude: 2 }, 'uid-1')),
    ).rejects.toThrow('Only EMS accounts can publish a location update.');
  });

  it('throws invalid-argument when patientId/latitude/longitude are missing or the wrong type', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    await expect(
      publishEmsLocation.run(fakeCallableRequest({ patientId: '', latitude: 1, longitude: 2 }, 'uid-1')),
    ).rejects.toThrow('patientId, latitude, and longitude are required.');
  });

  it('throws not-found when the patient does not exist', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    mockPatientGet.mockResolvedValue({ exists: false, data: () => undefined });
    await expect(
      publishEmsLocation.run(fakeCallableRequest({ patientId: 'missing', latitude: 1, longitude: 2 }, 'uid-1')),
    ).rejects.toThrow('No patient found with id missing.');
  });

  it('throws permission-denied when the patient belongs to a different organization', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    mockPatientGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-2' }) });
    await expect(
      publishEmsLocation.run(fakeCallableRequest({ patientId: 'p1', latitude: 1, longitude: 2 }, 'uid-1')),
    ).rejects.toThrow('That patient belongs to a different organization.');
  });

  it('publishes an active-location event to Pub/Sub on success', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    mockPatientGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1' }) });

    const result = await publishEmsLocation.run(
      fakeCallableRequest({ patientId: 'p1', latitude: 43.65, longitude: -79.38 }, 'uid-1'),
    );

    expect(mockTopic).toHaveBeenCalledWith('ems-location-updates');
    expect(mockPublishMessage).toHaveBeenCalledWith({
      json: { patientId: 'p1', organizationId: 'org-1', active: true, latitude: 43.65, longitude: -79.38 },
    });
    expect(result).toEqual({ published: true });
  });
});

describe('stopEmsLocation', () => {
  it('throws permission-denied for a non-EMS caller', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'] });
    await expect(stopEmsLocation.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'))).rejects.toThrow(
      'Only EMS accounts can stop a location update.',
    );
  });

  it('throws invalid-argument when patientId is missing', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    await expect(stopEmsLocation.run(fakeCallableRequest({ patientId: '' }, 'uid-1'))).rejects.toThrow(
      'patientId is required.',
    );
  });

  it('publishes an inactive-location event with no lat/lng', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    mockPatientGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1' }) });

    const result = await stopEmsLocation.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'));

    expect(mockPublishMessage).toHaveBeenCalledWith({
      json: { patientId: 'p1', organizationId: 'org-1', active: false },
    });
    expect(result).toEqual({ published: true });
  });
});

describe('onEmsLocationEvent', () => {
  it('logs and does nothing when the message has no patientId', async () => {
    const consoleError = vi.spyOn(console, 'error').mockImplementation(() => undefined);

    await onEmsLocationEvent.run({ data: { message: { json: {} } } } as never);

    expect(consoleError).toHaveBeenCalled();
    expect(mockPatientLocationRef).not.toHaveBeenCalled();
    consoleError.mockRestore();
  });

  it('merges active/organizationId (no lat/lng) when the event carries none, and never runs the proximity check', async () => {
    await onEmsLocationEvent.run({
      data: { message: { json: { patientId: 'p1', organizationId: 'org-1', active: false } } },
    } as never);

    expect(mockPatientLocationRef).toHaveBeenCalledWith('p1');
    expect(mockLocationSet).toHaveBeenCalledWith(
      { patientId: 'p1', organizationId: 'org-1', active: false, updatedAt: 'SERVER_TIMESTAMP' },
      { merge: true },
    );
    expect(mockLocationGet).not.toHaveBeenCalled();
  });

  it('includes latitude/longitude in the merge when the event carries a real fix', async () => {
    await onEmsLocationEvent.run(activeLocationEvent());

    expect(mockLocationSet).toHaveBeenCalledWith(
      expect.objectContaining({ latitude: 43.6, longitude: -79.4 }),
      { merge: true },
    );
  });

  it('clears connectivityAlertSentAt in the same merge when a real fix arrives', async () => {
    await onEmsLocationEvent.run(activeLocationEvent());

    expect(mockLocationSet).toHaveBeenCalledWith(
      expect.objectContaining({ connectivityAlertSentAt: 'FIELD_DELETED' }),
      { merge: true },
    );
  });

  it('does not run the proximity check when active but the event carries no fix', async () => {
    await onEmsLocationEvent.run({
      data: { message: { json: { patientId: 'p1', organizationId: 'org-1', active: true } } },
    } as never);

    expect(mockLocationGet).not.toHaveBeenCalled();
  });

  describe('explicit opt-out (active: false)', () => {
    it('does nothing further when the patient has no (string) createdBy on record', async () => {
      mockPatientGet.mockResolvedValue({ data: () => undefined });

      await onEmsLocationEvent.run({
        data: { message: { json: { patientId: 'p1', organizationId: 'org-1', active: false } } },
      } as never);

      expect(mockSendAlertPush).not.toHaveBeenCalled();
    });

    it('does nothing further when the EMS account on record has no user doc', async () => {
      mockPatientGet.mockResolvedValue({ data: () => ({ createdBy: 'ems-uid' }) });
      mockUsersGet.mockResolvedValue({ exists: false, data: () => undefined });

      await onEmsLocationEvent.run({
        data: { message: { json: { patientId: 'p1', organizationId: 'org-1', active: false } } },
      } as never);

      expect(mockSendAlertPush).not.toHaveBeenCalled();
    });

    it('sends a "stopped sharing" push to the patient-creating EMS account', async () => {
      mockPatientGet.mockResolvedValue({ data: () => ({ createdBy: 'ems-uid' }) });
      mockUsersGet.mockResolvedValue({ exists: true, ref: 'USER_REF_ems-uid', data: () => ({ fcmTokens: ['token-1'] }) });

      await onEmsLocationEvent.run({
        data: { message: { json: { patientId: 'p1', organizationId: 'org-1', active: false } } },
      } as never);

      expect(mockSendAlertPush).toHaveBeenCalledWith(
        [{ ref: 'USER_REF_ems-uid', data: expect.any(Function) }],
        'Tracking interrupted',
        'Location sharing was turned off for a patient still marked active.',
      );
      // Confirms the wrapped data() actually forwards the real doc data,
      // not just a matching shape.
      expect(mockSendAlertPush.mock.calls[0][0][0].data()).toEqual({ fcmTokens: ['token-1'] });
    });

    it('does not fire the opt-out push for an active: true event', async () => {
      mockPatientGet.mockResolvedValue({ data: () => ({ createdBy: 'ems-uid' }) });
      mockUsersGet.mockResolvedValue({ exists: true, ref: 'USER_REF_ems-uid', data: () => ({ fcmTokens: ['token-1'] }) });

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(mockSendAlertPush).not.toHaveBeenCalled();
    });
  });

  describe('proximity-alert threshold check', () => {
    it('skips the ETA recheck entirely when the last one was under a minute ago (throttle)', async () => {
      mockLocationGet.mockResolvedValue({ data: () => ({ lastEtaCheckAt: { toMillis: () => Date.now() - 10_000 } }) });

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(mockPatientGet).not.toHaveBeenCalled();
    });

    it('proceeds past the throttle once a minute has elapsed', async () => {
      mockLocationGet.mockResolvedValue({ data: () => ({ lastEtaCheckAt: { toMillis: () => Date.now() - 120_000 } }) });

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(mockPatientGet).toHaveBeenCalled();
    });

    it('skips even the patient/hospital lookup once every threshold has already been notified', async () => {
      mockLocationGet.mockResolvedValue({ data: () => ({ notifiedThresholds: [30, 15, 5] }) });

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(mockPatientGet).not.toHaveBeenCalled();
      expect(mockLocationSet).toHaveBeenLastCalledWith({ lastEtaCheckAt: 'SERVER_TIMESTAMP' }, { merge: true });
    });

    it('skips the real Directions call (haversine pre-filter) when nowhere near the next threshold', async () => {
      mockPatientGet.mockResolvedValue({ data: () => ({ organizationId: 'org-1', destination: 'General Hospital' }) });
      // Roughly 130+ km from activeLocationEvent()'s (43.6, -79.4) fix —
      // far enough that even the slow ASSUMED_AVERAGE_SPEED_KMH estimate
      // clears every threshold's margin, so this should never reach fetch.
      mockHospitalsGet.mockResolvedValue({ docs: [{ data: () => ({ latitude: 44.5, longitude: -80.5 }) }] });
      const fetchSpy = vi.fn();
      vi.stubGlobal('fetch', fetchSpy);

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(fetchSpy).not.toHaveBeenCalled();
      expect(mockNotifyPatientProximity).not.toHaveBeenCalled();
      expect(mockLocationSet).toHaveBeenLastCalledWith({ lastEtaCheckAt: 'SERVER_TIMESTAMP' }, { merge: true });
    });

    it('stops (no hospital lookup) when the patient has no organizationId/destination yet', async () => {
      mockPatientGet.mockResolvedValue({ data: () => ({}) });

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(mockHospitalsWhere1).not.toHaveBeenCalled();
      expect(mockNotifyPatientProximity).not.toHaveBeenCalled();
    });

    it('stamps lastEtaCheckAt only (no notify) when the destination hospital cannot be resolved', async () => {
      mockPatientGet.mockResolvedValue({ data: () => ({ organizationId: 'org-1', destination: 'General Hospital' }) });
      mockHospitalsGet.mockResolvedValue({ docs: [] });

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(mockNotifyPatientProximity).not.toHaveBeenCalled();
      expect(mockLocationSet).toHaveBeenLastCalledWith({ lastEtaCheckAt: 'SERVER_TIMESTAMP' }, { merge: true });
    });

    it('stamps lastEtaCheckAt only (no notify) when a hospital is found but the Directions API finds no route', async () => {
      mockPatientGet.mockResolvedValue({ data: () => ({ organizationId: 'org-1', destination: 'General Hospital' }) });
      mockHospitalsGet.mockResolvedValue({ docs: [{ data: () => ({ latitude: 43.7, longitude: -79.5 }) }] });
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ json: () => Promise.resolve({ status: 'ZERO_RESULTS', routes: [] }) }));

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(mockNotifyPatientProximity).not.toHaveBeenCalled();
      expect(mockLocationSet).toHaveBeenLastCalledWith({ lastEtaCheckAt: 'SERVER_TIMESTAMP' }, { merge: true });
    });

    it('logs and stamps lastEtaCheckAt only (no notify) when the Directions API call itself throws', async () => {
      mockPatientGet.mockResolvedValue({ data: () => ({ organizationId: 'org-1', destination: 'General Hospital' }) });
      mockHospitalsGet.mockResolvedValue({ docs: [{ data: () => ({ latitude: 43.7, longitude: -79.5 }) }] });
      vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network error')));

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(mockLoggerError).toHaveBeenCalledWith('Failed to check proximity-alert thresholds', expect.any(Error));
      expect(mockNotifyPatientProximity).not.toHaveBeenCalled();
      expect(mockLocationSet).toHaveBeenLastCalledWith({ lastEtaCheckAt: 'SERVER_TIMESTAMP' }, { merge: true });
    });

    it('stamps lastEtaCheckAt only (no notify, no notifiedThresholds write) when ETA has not crossed any threshold yet', async () => {
      mockPatientGet.mockResolvedValue({ data: () => ({ organizationId: 'org-1', destination: 'General Hospital' }) });
      mockHospitalsGet.mockResolvedValue({ docs: [{ data: () => ({ latitude: 43.7, longitude: -79.5 }) }] });
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(okDirectionsResponse(90 * 60))); // 90 minutes

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(mockNotifyPatientProximity).not.toHaveBeenCalled();
      expect(mockLocationSet).toHaveBeenLastCalledWith({ lastEtaCheckAt: 'SERVER_TIMESTAMP' }, { merge: true });
    });

    it('notifies and records every newly-crossed threshold when ETA drops under them', async () => {
      const patient = { organizationId: 'org-1', destination: 'General Hospital', age: 42, gender: 'Male' };
      mockPatientGet.mockResolvedValue({ data: () => patient });
      mockHospitalsGet.mockResolvedValue({ docs: [{ data: () => ({ latitude: 43.7, longitude: -79.5 }) }] });
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(okDirectionsResponse(10 * 60))); // 10 minutes -> crosses 30 and 15

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(mockNotifyPatientProximity).toHaveBeenCalledWith(patient, [30, 15]);
      expect(mockLocationSet).toHaveBeenLastCalledWith(
        { lastEtaCheckAt: 'SERVER_TIMESTAMP', notifiedThresholds: { __arrayUnion: [30, 15] } },
        { merge: true },
      );
    });

    it('excludes already-notified thresholds from a new crossing', async () => {
      mockLocationGet.mockResolvedValue({ data: () => ({ notifiedThresholds: [30] }) });
      mockPatientGet.mockResolvedValue({ data: () => ({ organizationId: 'org-1', destination: 'General Hospital' }) });
      mockHospitalsGet.mockResolvedValue({ docs: [{ data: () => ({ latitude: 43.7, longitude: -79.5 }) }] });
      vi.stubGlobal('fetch', vi.fn().mockResolvedValue(okDirectionsResponse(10 * 60))); // still crosses 30 and 15

      await onEmsLocationEvent.run(activeLocationEvent());

      expect(mockNotifyPatientProximity).toHaveBeenCalledWith(expect.anything(), [15]);
    });
  });
});

describe('checkEmsConnectivity', () => {
  it('queries only active patients, and does nothing when none are being tracked', async () => {
    mockPatientsActiveGet.mockResolvedValue({ docs: [] });

    await checkEmsConnectivity.run({} as never);

    expect(mockPatientsWhere).toHaveBeenCalledWith('status', '==', 'active');
    expect(mockSendAlertPush).not.toHaveBeenCalled();
  });

  it('skips a patient with no location/current doc at all yet', async () => {
    mockPatientsActiveGet.mockResolvedValue({ docs: [{ id: 'p1' }] });
    mockLocationGet.mockResolvedValue({ data: () => undefined });

    await checkEmsConnectivity.run({} as never);

    expect(mockSendAlertPush).not.toHaveBeenCalled();
    expect(mockLocationSet).not.toHaveBeenCalled();
  });

  it('skips a patient already explicitly stopped (active: false) — the opt-out hook already covered it', async () => {
    mockPatientsActiveGet.mockResolvedValue({ docs: [{ id: 'p1' }] });
    mockLocationGet.mockResolvedValue({
      data: () => ({ active: false, updatedAt: { toMillis: () => Date.now() - 10 * 60 * 1000 } }),
    });

    await checkEmsConnectivity.run({} as never);

    expect(mockSendAlertPush).not.toHaveBeenCalled();
  });

  it('skips a patient already alerted for this ongoing silence episode', async () => {
    mockPatientsActiveGet.mockResolvedValue({ docs: [{ id: 'p1' }] });
    mockLocationGet.mockResolvedValue({
      data: () => ({
        active: true,
        connectivityAlertSentAt: 'ALREADY_SET',
        updatedAt: { toMillis: () => Date.now() - 10 * 60 * 1000 },
      }),
    });

    await checkEmsConnectivity.run({} as never);

    expect(mockSendAlertPush).not.toHaveBeenCalled();
  });

  it('skips a patient whose last fix is not yet stale', async () => {
    mockPatientsActiveGet.mockResolvedValue({ docs: [{ id: 'p1' }] });
    mockLocationGet.mockResolvedValue({
      data: () => ({ active: true, updatedAt: { toMillis: () => Date.now() - 5_000 } }),
    });

    await checkEmsConnectivity.run({} as never);

    expect(mockSendAlertPush).not.toHaveBeenCalled();
  });

  it('skips a patient whose location has no updatedAt at all', async () => {
    mockPatientsActiveGet.mockResolvedValue({ docs: [{ id: 'p1' }] });
    mockLocationGet.mockResolvedValue({ data: () => ({ active: true }) });

    await checkEmsConnectivity.run({} as never);

    expect(mockSendAlertPush).not.toHaveBeenCalled();
  });

  it('notifies and stamps connectivityAlertSentAt once a fix has gone stale past the threshold', async () => {
    mockPatientsActiveGet.mockResolvedValue({ docs: [{ id: 'p1' }] });
    mockLocationGet.mockResolvedValue({
      data: () => ({ active: true, updatedAt: { toMillis: () => Date.now() - 120_000 } }),
    });
    mockPatientGet.mockResolvedValue({ data: () => ({ createdBy: 'ems-uid' }) });
    mockUsersGet.mockResolvedValue({ exists: true, ref: 'USER_REF_ems-uid', data: () => ({ fcmTokens: ['token-1'] }) });

    await checkEmsConnectivity.run({} as never);

    expect(mockSendAlertPush).toHaveBeenCalledWith(
      [{ ref: 'USER_REF_ems-uid', data: expect.any(Function) }],
      'Tracking interrupted',
      "A tracked patient's location hasn't updated recently — check the device's signal and battery.",
    );
    expect(mockLocationSet).toHaveBeenCalledWith({ connectivityAlertSentAt: 'SERVER_TIMESTAMP' }, { merge: true });
  });

  it('checks every active patient independently, in parallel', async () => {
    mockPatientsActiveGet.mockResolvedValue({ docs: [{ id: 'p1' }, { id: 'p2' }] });
    mockLocationGet.mockResolvedValue({ data: () => undefined });

    await checkEmsConnectivity.run({} as never);

    expect(mockPatientLocationRef).toHaveBeenCalledWith('p1');
    expect(mockPatientLocationRef).toHaveBeenCalledWith('p2');
  });
});

describe('onPatientDeleted', () => {
  it('recursively deletes the patient doc (and its location/vitalsHistory subcollections)', async () => {
    await onPatientDeleted.run(fakeDocumentEvent({}, { patientId: 'p1' }) as never);

    expect(mockRecursiveDelete).toHaveBeenCalledWith({ get: mockPatientGet, id: 'p1' });
  });
});
