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
  mockPatientLocationRef,
} = vi.hoisted(() => {
  const mockPublishMessage = vi.fn();
  const mockPatientGet = vi.fn();
  return {
    mockPatientGet,
    mockCollection: vi.fn((name: string) => {
      if (name !== 'patients') throw new Error(`Unexpected collection in test: ${name}`);
      return { doc: (id: string) => ({ get: mockPatientGet, id }) };
    }),
    mockRecursiveDelete: vi.fn(),
    mockGetCallerProfile: vi.fn(),
    mockPublishMessage,
    mockTopic: vi.fn(() => ({ publishMessage: mockPublishMessage })),
    mockLocationSet: vi.fn(),
    mockPatientLocationRef: vi.fn(() => ({ set: mockLocationSet })),
  };
});

vi.mock('@google-cloud/pubsub', () => ({
  PubSub: vi.fn(function (this: Record<string, unknown>) {
    this['topic'] = mockTopic;
  }),
}));

vi.mock('firebase-admin/firestore', () => ({
  getFirestore: () => ({ collection: mockCollection, recursiveDelete: mockRecursiveDelete }),
  FieldValue: { serverTimestamp: () => 'SERVER_TIMESTAMP' },
}));

vi.mock('./auth', () => ({
  REGION: 'northamerica-northeast2',
  getCallerProfile: mockGetCallerProfile,
}));

vi.mock('./patient-data', () => ({
  patientLocationRef: mockPatientLocationRef,
}));

import { onEmsLocationEvent, onPatientDeleted, publishEmsLocation, stopEmsLocation } from './ems';

const EMS_PROFILE = { uid: 'ems-uid', email: 'ems@example.com', role: ['ems'], organizationId: 'org-1' };

beforeEach(() => {
  vi.resetAllMocks();
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

  it('merges active/organizationId (no lat/lng) when the event carries none', async () => {
    await onEmsLocationEvent.run({
      data: { message: { json: { patientId: 'p1', organizationId: 'org-1', active: false } } },
    } as never);

    expect(mockPatientLocationRef).toHaveBeenCalledWith('p1');
    expect(mockLocationSet).toHaveBeenCalledWith(
      { patientId: 'p1', organizationId: 'org-1', active: false, updatedAt: 'SERVER_TIMESTAMP' },
      { merge: true },
    );
  });

  it('includes latitude/longitude in the merge when the event carries a real fix', async () => {
    await onEmsLocationEvent.run({
      data: { message: { json: { patientId: 'p1', organizationId: 'org-1', active: true, latitude: 43.65, longitude: -79.38 } } },
    } as never);

    expect(mockLocationSet).toHaveBeenCalledWith(
      expect.objectContaining({ latitude: 43.65, longitude: -79.38 }),
      { merge: true },
    );
  });
});

describe('onPatientDeleted', () => {
  it('recursively deletes the patient doc (and its location/vitalsHistory subcollections)', async () => {
    await onPatientDeleted.run(fakeDocumentEvent({}, { patientId: 'p1' }) as never);

    expect(mockRecursiveDelete).toHaveBeenCalledWith({ get: mockPatientGet, id: 'p1' });
  });
});
