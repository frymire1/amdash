import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fakeCallableRequest } from './test-utils';

// vi.hoisted() is required (not plain top-level consts) — see
// audit.test.ts's comment for why.
const { mockUsersWhere1, mockUsersWhere2, mockUsersWhere3, mockUsersWhere4, mockUsersGet, mockCollection, mockTimestampNow, mockSendEachForMulticast, mockGetCallerProfile } =
  vi.hoisted(() => {
    const mockUsersGet = vi.fn();
    const mockUsersWhere4 = vi.fn(() => ({ get: mockUsersGet }));
    const mockUsersWhere3 = vi.fn(() => ({ where: mockUsersWhere4 }));
    const mockUsersWhere2 = vi.fn(() => ({ where: mockUsersWhere3 }));
    const mockUsersWhere1 = vi.fn(() => ({ where: mockUsersWhere2 }));

    return {
      mockUsersWhere1,
      mockUsersWhere2,
      mockUsersWhere3,
      mockUsersWhere4,
      mockUsersGet,
      mockCollection: vi.fn((name: string) => {
        if (name === 'users') return { where: mockUsersWhere1 };
        throw new Error(`Unexpected collection in test: ${name}`);
      }),
      mockTimestampNow: vi.fn(() => 'FAKE_NOW'),
      mockSendEachForMulticast: vi.fn(),
      mockGetCallerProfile: vi.fn(),
    };
  });

vi.mock('firebase-admin/firestore', () => ({
  getFirestore: () => ({ collection: mockCollection }),
  FieldValue: { arrayRemove: (...tokens: string[]) => ({ __arrayRemove: tokens }) },
  Timestamp: { now: mockTimestampNow },
}));

vi.mock('firebase-admin/messaging', () => ({
  getMessaging: () => ({ sendEachForMulticast: mockSendEachForMulticast }),
}));

vi.mock('firebase-functions/params', () => ({
  defineSecret: () => ({ value: () => 'fake-directions-api-key' }),
}));

vi.mock('./auth', () => ({
  REGION: 'northamerica-northeast2',
  getCallerProfile: mockGetCallerProfile,
}));

import { demographicText, fetchDirections, isProvided, isUnregisteredError, notifyPatientProximity, sendAlertPush } from './physician';

// A hand-traced-correct minimal encoded polyline: "AA" decodes to exactly
// one point at (1/1e5, 1/1e5) — see directions.test.ts's identical comment
// for the full hand-trace.
const ONE_POINT_ENCODED_POLYLINE = 'AA';
const ONE_POINT_DECODED = [1 / 1e5, 1 / 1e5];

function mockDirectionsFetchResponse(body: unknown) {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ json: () => Promise.resolve(body) }));
}

const OK_DIRECTIONS_RESPONSE = {
  status: 'OK',
  routes: [
    {
      legs: [{ duration: { text: '12 mins', value: 720 }, distance: { text: '5.2 km', value: 5200 } }],
      overview_polyline: { points: ONE_POINT_ENCODED_POLYLINE },
    },
  ],
};

beforeEach(() => {
  vi.resetAllMocks();
  vi.unstubAllGlobals();
});

describe('fetchDirections', () => {
  it('requires the caller to be signed in (propagates getCallerProfile\'s own unauthenticated error)', async () => {
    mockGetCallerProfile.mockRejectedValue(new Error('You must be signed in.'));
    await expect(
      fetchDirections.run(fakeCallableRequest({ originLat: 1, originLng: 2, destinationLat: 3, destinationLng: 4 })),
    ).rejects.toThrow('You must be signed in.');
  });

  it('throws invalid-argument when any coordinate is missing or the wrong type', async () => {
    mockGetCallerProfile.mockResolvedValue({ uid: 'u1' });
    await expect(
      fetchDirections.run(fakeCallableRequest({ originLat: 1, originLng: 2, destinationLat: 3 } as never, 'u1')),
    ).rejects.toThrow('originLat, originLng, destinationLat, and destinationLng are required.');
  });

  it('returns found: false when the Directions API reports no route (e.g. ZERO_RESULTS)', async () => {
    mockGetCallerProfile.mockResolvedValue({ uid: 'u1' });
    mockDirectionsFetchResponse({ status: 'ZERO_RESULTS', routes: [] });

    const result = await fetchDirections.run(
      fakeCallableRequest({ originLat: 1, originLng: 2, destinationLat: 3, destinationLng: 4 }, 'u1'),
    );

    expect(result).toEqual({ found: false });
  });

  it('returns the decoded route on success, without leaking durationSeconds', async () => {
    mockGetCallerProfile.mockResolvedValue({ uid: 'u1' });
    mockDirectionsFetchResponse(OK_DIRECTIONS_RESPONSE);

    const result = await fetchDirections.run(
      fakeCallableRequest({ originLat: 1, originLng: 2, destinationLat: 3, destinationLng: 4 }, 'u1'),
    );

    expect(result).toEqual({
      found: true,
      durationText: '12 mins',
      distanceText: '5.2 km',
      polylinePoints: [ONE_POINT_DECODED],
    });
  });
});

describe('isProvided', () => {
  it('treats any number (including 0) as provided', () => {
    expect(isProvided(0)).toBe(true);
    expect(isProvided(42)).toBe(true);
  });

  it('treats a non-empty string other than the "Unknown" sentinel as provided', () => {
    expect(isProvided('Male')).toBe(true);
  });

  it('treats an empty string as not provided', () => {
    expect(isProvided('')).toBe(false);
  });

  it('treats the literal "Unknown" sentinel as not provided', () => {
    expect(isProvided('Unknown')).toBe(false);
  });

  it('treats null/undefined/other types as not provided', () => {
    expect(isProvided(null)).toBe(false);
    expect(isProvided(undefined)).toBe(false);
  });
});

describe('demographicText', () => {
  it('combines age and gender when both are known', () => {
    expect(demographicText(42, 'Male')).toBe('42, Male');
  });

  it('uses only age when gender is unprovided', () => {
    expect(demographicText(42, 'Unknown')).toBe('42');
  });

  it('uses only gender when age is unprovided', () => {
    expect(demographicText('Unknown', 'Male')).toBe('Male');
  });

  it('falls back to "A patient" when neither is provided', () => {
    expect(demographicText('Unknown', 'Unknown')).toBe('A patient');
  });
});

describe('isUnregisteredError', () => {
  it('is true for messaging/registration-token-not-registered', () => {
    expect(isUnregisteredError({ code: 'messaging/registration-token-not-registered' })).toBe(true);
  });

  it('is false for any other error code, and for undefined', () => {
    expect(isUnregisteredError({ code: 'messaging/internal-error' })).toBe(false);
    expect(isUnregisteredError(undefined)).toBe(false);
  });
});

describe('sendAlertPush', () => {
  it('is a no-op when no matching user has an FCM token registered', async () => {
    await sendAlertPush({ docs: [{ ref: {}, data: () => ({ fcmTokens: [] }) }] } as never, 'Title', 'Body');
    expect(mockSendEachForMulticast).not.toHaveBeenCalled();
  });

  it('is also a no-op when a matching user doc has no fcmTokens field at all', async () => {
    await sendAlertPush({ docs: [{ ref: {}, data: () => ({}) }] } as never, 'Title', 'Body');
    expect(mockSendEachForMulticast).not.toHaveBeenCalled();
  });

  it('sends one multicast across every matching token', async () => {
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await sendAlertPush({ docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }] } as never, 'Title', 'Body');

    expect(mockSendEachForMulticast).toHaveBeenCalledWith({ tokens: ['token-1'], data: { title: 'Title', body: 'Body' } });
  });

  it('prunes a token FCM reports as unregistered from the owning user doc', async () => {
    const userRef = { update: vi.fn() };
    mockSendEachForMulticast.mockResolvedValue({
      failureCount: 1,
      responses: [
        { success: false, error: { code: 'messaging/registration-token-not-registered' } },
        { success: true },
      ],
    });

    await sendAlertPush(
      { docs: [{ ref: userRef, data: () => ({ fcmTokens: ['dead-token', 'live-token'] }) }] } as never,
      'Title',
      'Body',
    );

    expect(userRef.update).toHaveBeenCalledWith({ fcmTokens: { __arrayRemove: ['dead-token'] } });
  });

  it('does not touch any user doc when a send fails for a reason other than an unregistered token', async () => {
    const userRef = { update: vi.fn() };
    mockSendEachForMulticast.mockResolvedValue({
      failureCount: 1,
      responses: [{ success: false, error: { code: 'messaging/internal-error' } }],
    });

    await sendAlertPush({ docs: [{ ref: userRef, data: () => ({ fcmTokens: ['token-1'] }) }] } as never, 'Title', 'Body');

    expect(userRef.update).not.toHaveBeenCalled();
  });
});

describe('notifyPatientProximity', () => {
  const patient = { organizationId: 'org-1', destination: 'General Hospital', age: 42, gender: 'Male' };

  it('queries for physicians matching org/hospital/armed/threshold, and is a no-op when none match', async () => {
    mockUsersGet.mockResolvedValue({ empty: true, docs: [] });

    await notifyPatientProximity(patient, [30]);

    expect(mockUsersWhere1).toHaveBeenCalledWith('organizationId', '==', 'org-1');
    expect(mockUsersWhere2).toHaveBeenCalledWith('workLocation', '==', 'General Hospital');
    expect(mockUsersWhere3).toHaveBeenCalledWith('newPatientAlertsExpiresAt', '>', 'FAKE_NOW');
    expect(mockUsersWhere4).toHaveBeenCalledWith('etaAlertThresholdsMinutes', 'array-contains-any', [30]);
    expect(mockSendEachForMulticast).not.toHaveBeenCalled();
  });

  it('sends a demographic-based message naming only the smallest newly-crossed threshold', async () => {
    mockUsersGet.mockResolvedValue({
      empty: false,
      docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }],
    });
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await notifyPatientProximity(patient, [60, 30]);

    expect(mockSendEachForMulticast).toHaveBeenCalledWith({
      tokens: ['token-1'],
      data: { title: 'Patient approaching', body: '42, Male is about 30 minutes away.' },
    });
  });

  it('falls back to "A patient" when age/gender are both unprovided', async () => {
    mockUsersGet.mockResolvedValue({
      empty: false,
      docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }],
    });
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await notifyPatientProximity({ ...patient, age: 'Unknown', gender: 'Unknown' }, [5]);

    expect(mockSendEachForMulticast).toHaveBeenCalledWith(
      expect.objectContaining({ data: { title: 'Patient approaching', body: 'A patient is about 5 minutes away.' } }),
    );
  });
});
