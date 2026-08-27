import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fakeCallableRequest, fakeDocumentEvent } from './test-utils';

// vi.hoisted() is required (not plain top-level consts) — see
// audit.test.ts's comment for why.
const {
  mockUsersWhere1,
  mockUsersWhere2,
  mockUsersWhere3,
  mockUsersGet,
  mockHospitalsWhere1,
  mockHospitalsWhere2,
  mockHospitalsLimit,
  mockHospitalsGet,
  mockLocationGet,
  mockPatientLocationRef,
  mockCollection,
  mockTimestampNow,
  mockSendEachForMulticast,
  mockGetCallerProfile,
  mockLoggerError,
} = vi.hoisted(() => {
  const mockUsersGet = vi.fn();
  const mockUsersWhere3 = vi.fn(() => ({ get: mockUsersGet }));
  const mockUsersWhere2 = vi.fn(() => ({ where: mockUsersWhere3 }));
  const mockUsersWhere1 = vi.fn(() => ({ where: mockUsersWhere2 }));

  const mockHospitalsGet = vi.fn();
  const mockHospitalsLimit = vi.fn(() => ({ get: mockHospitalsGet }));
  const mockHospitalsWhere2 = vi.fn(() => ({ limit: mockHospitalsLimit }));
  const mockHospitalsWhere1 = vi.fn(() => ({ where: mockHospitalsWhere2 }));

  return {
    mockUsersWhere1,
    mockUsersWhere2,
    mockUsersWhere3,
    mockUsersGet,
    mockHospitalsWhere1,
    mockHospitalsWhere2,
    mockHospitalsLimit,
    mockHospitalsGet,
    mockLocationGet: vi.fn(),
    mockPatientLocationRef: vi.fn(() => ({ get: mockLocationGet })),
    mockCollection: vi.fn((name: string) => {
      if (name === 'users') return { where: mockUsersWhere1 };
      if (name === 'hospitals') return { where: mockHospitalsWhere1 };
      throw new Error(`Unexpected collection in test: ${name}`);
    }),
    mockTimestampNow: vi.fn(() => 'FAKE_NOW'),
    mockSendEachForMulticast: vi.fn(),
    mockGetCallerProfile: vi.fn(),
    mockLoggerError: vi.fn(),
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

vi.mock('firebase-functions/v2', () => ({
  logger: { error: mockLoggerError },
}));

vi.mock('./auth', () => ({
  REGION: 'northamerica-northeast2',
  getCallerProfile: mockGetCallerProfile,
}));

vi.mock('./patient-data', () => ({
  patientLocationRef: mockPatientLocationRef,
}));

import { fetchDirections, sendNewPatientAlerts } from './physician';

// A hand-traced-correct minimal encoded polyline: "AA" decodes to exactly
// one point at (1/1e5, 1/1e5) — verified by walking decodePolyline's own
// bit-shifting logic by hand rather than trusting a remembered "canonical"
// example, since getting this fixture wrong would make the test pass for
// the wrong reason.
const ONE_POINT_ENCODED_POLYLINE = 'AA';
const ONE_POINT_DECODED = [1 / 1e5, 1 / 1e5];

// Same hand-tracing exercise as ONE_POINT_ENCODED_POLYLINE, but for a
// *negative* delta — decodePolyline's sign-handling branch
// (`result & 1 ? ~(result >> 1) : ...`) is only reachable with an odd
// decoded value, which only a negative original delta produces. Encoding
// -1 (delta -0.00001): shifted = -1<<1 = -2; negative, so invert: ~(-2) = 1;
// 1 < 0x20, single char chr(1+63) = '@'. Decoding '@' back: b=1, result=1,
// odd → lat += ~(1>>1) = ~0 = -1 → -1/1e5. Traced by hand, not remembered.
const NEGATIVE_POINT_ENCODED_POLYLINE = '@@';
const NEGATIVE_POINT_DECODED = [-1 / 1e5, -1 / 1e5];

function mockDirectionsFetchResponse(body: unknown) {
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({ json: () => Promise.resolve(body) }),
  );
}

const OK_DIRECTIONS_RESPONSE = {
  status: 'OK',
  routes: [
    {
      legs: [{ duration: { text: '12 mins' }, distance: { text: '5.2 km' } }],
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

  it('returns the decoded route on success', async () => {
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

  it('decodes a negative-delta polyline point correctly (decodePolyline\'s sign-handling branch)', async () => {
    mockGetCallerProfile.mockResolvedValue({ uid: 'u1' });
    mockDirectionsFetchResponse({
      status: 'OK',
      routes: [
        {
          legs: [{ duration: { text: '1 min' }, distance: { text: '1 km' } }],
          overview_polyline: { points: NEGATIVE_POINT_ENCODED_POLYLINE },
        },
      ],
    });

    const result = await fetchDirections.run(
      fakeCallableRequest({ originLat: 1, originLng: 2, destinationLat: 3, destinationLng: 4 }, 'u1'),
    );

    expect(result).toEqual(expect.objectContaining({ polylinePoints: [NEGATIVE_POINT_DECODED] }));
  });
});

describe('sendNewPatientAlerts', () => {
  const patientData = { organizationId: 'org-1', destination: 'General Hospital', age: 42, gender: 'Male' };

  it('is a no-op when the new patient has no organizationId or destination yet', async () => {
    await sendNewPatientAlerts.run(fakeDocumentEvent({ organizationId: 'org-1' }, { patientId: 'p1' }) as never);
    expect(mockUsersWhere1).not.toHaveBeenCalled();
  });

  it('is a no-op when no matching physician has an FCM token registered', async () => {
    mockUsersGet.mockResolvedValue({ docs: [{ ref: {}, data: () => ({ fcmTokens: [] }) }] });

    await sendNewPatientAlerts.run(fakeDocumentEvent(patientData, { patientId: 'p1' }) as never);

    expect(mockSendEachForMulticast).not.toHaveBeenCalled();
  });

  it('is also a no-op when a matching user doc has no fcmTokens field at all', async () => {
    mockUsersGet.mockResolvedValue({ docs: [{ ref: {}, data: () => ({}) }] });

    await sendNewPatientAlerts.run(fakeDocumentEvent(patientData, { patientId: 'p1' }) as never);

    expect(mockSendEachForMulticast).not.toHaveBeenCalled();
  });

  it('sends a demographic-only notification when no live location fix is available', async () => {
    mockUsersGet.mockResolvedValue({ docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }] });
    mockLocationGet.mockResolvedValue({ data: () => undefined });
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await sendNewPatientAlerts.run(fakeDocumentEvent(patientData, { patientId: 'p1' }) as never);

    expect(mockSendEachForMulticast).toHaveBeenCalledWith({
      tokens: ['token-1'],
      data: { title: 'New patient inbound', body: '42, Male is inbound.' },
    });
  });

  it('includes an ETA in the notification body when a route is found', async () => {
    mockUsersGet.mockResolvedValue({ docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }] });
    mockLocationGet.mockResolvedValue({ data: () => ({ latitude: 43.6, longitude: -79.4 }) });
    mockHospitalsGet.mockResolvedValue({ docs: [{ data: () => ({ latitude: 43.7, longitude: -79.5 }) }] });
    mockDirectionsFetchResponse(OK_DIRECTIONS_RESPONSE);
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await sendNewPatientAlerts.run(fakeDocumentEvent(patientData, { patientId: 'p1' }) as never);

    expect(mockSendEachForMulticast).toHaveBeenCalledWith({
      tokens: ['token-1'],
      data: { title: 'New patient inbound', body: '42, Male is arriving in 12 mins.' },
    });
  });

  it('falls back to "A patient" when age/gender are both unprovided ("Unknown" sentinel)', async () => {
    mockUsersGet.mockResolvedValue({ docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }] });
    mockLocationGet.mockResolvedValue({ data: () => undefined });
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await sendNewPatientAlerts.run(
      fakeDocumentEvent({ ...patientData, age: 'Unknown', gender: 'Unknown' }, { patientId: 'p1' }) as never,
    );

    expect(mockSendEachForMulticast).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ body: 'A patient is inbound.' }) }),
    );
  });

  it('uses only the age when gender is unprovided', async () => {
    mockUsersGet.mockResolvedValue({ docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }] });
    mockLocationGet.mockResolvedValue({ data: () => undefined });
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await sendNewPatientAlerts.run(fakeDocumentEvent({ ...patientData, gender: 'Unknown' }, { patientId: 'p1' }) as never);

    expect(mockSendEachForMulticast).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ body: '42 is inbound.' }) }),
    );
  });

  it('uses only the gender when age is unprovided', async () => {
    mockUsersGet.mockResolvedValue({ docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }] });
    mockLocationGet.mockResolvedValue({ data: () => undefined });
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await sendNewPatientAlerts.run(fakeDocumentEvent({ ...patientData, age: 'Unknown' }, { patientId: 'p1' }) as never);

    expect(mockSendEachForMulticast).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ body: 'Male is inbound.' }) }),
    );
  });

  it('also falls back to "A patient" when age/gender are neither a number nor a string at all', async () => {
    mockUsersGet.mockResolvedValue({ docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }] });
    mockLocationGet.mockResolvedValue({ data: () => undefined });
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await sendNewPatientAlerts.run(
      fakeDocumentEvent({ ...patientData, age: null, gender: undefined }, { patientId: 'p1' }) as never,
    );

    expect(mockSendEachForMulticast).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ body: 'A patient is inbound.' }) }),
    );
  });

  it('sends a demographic-only notification when a live fix exists but no hospital matches the destination', async () => {
    mockUsersGet.mockResolvedValue({ docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }] });
    mockLocationGet.mockResolvedValue({ data: () => ({ latitude: 43.6, longitude: -79.4 }) });
    mockHospitalsGet.mockResolvedValue({ docs: [] });
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await sendNewPatientAlerts.run(fakeDocumentEvent(patientData, { patientId: 'p1' }) as never);

    expect(mockSendEachForMulticast).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ body: '42, Male is inbound.' }) }),
    );
  });

  it('sends a demographic-only notification when the Directions API finds location/hospital but no actual route', async () => {
    mockUsersGet.mockResolvedValue({ docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }] });
    mockLocationGet.mockResolvedValue({ data: () => ({ latitude: 43.6, longitude: -79.4 }) });
    mockHospitalsGet.mockResolvedValue({ docs: [{ data: () => ({ latitude: 43.7, longitude: -79.5 }) }] });
    mockDirectionsFetchResponse({ status: 'ZERO_RESULTS', routes: [] });
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await sendNewPatientAlerts.run(fakeDocumentEvent(patientData, { patientId: 'p1' }) as never);

    expect(mockSendEachForMulticast).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ body: '42, Male is inbound.' }) }),
    );
  });

  it('sends a demographic-only notification (and logs the error) when the Directions API call itself throws', async () => {
    mockUsersGet.mockResolvedValue({ docs: [{ ref: {}, data: () => ({ fcmTokens: ['token-1'] }) }] });
    mockLocationGet.mockResolvedValue({ data: () => ({ latitude: 43.6, longitude: -79.4 }) });
    mockHospitalsGet.mockResolvedValue({ docs: [{ data: () => ({ latitude: 43.7, longitude: -79.5 }) }] });
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network error')));
    mockSendEachForMulticast.mockResolvedValue({ failureCount: 0, responses: [{ success: true }] });

    await sendNewPatientAlerts.run(fakeDocumentEvent(patientData, { patientId: 'p1' }) as never);

    expect(mockLoggerError).toHaveBeenCalledWith('Failed to estimate arrival duration for a new-patient alert', expect.any(Error));
    expect(mockSendEachForMulticast).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ body: '42, Male is inbound.' }) }),
    );
  });

  it('prunes a token FCM reports as unregistered from the owning user doc', async () => {
    const userRef = { update: vi.fn() };
    mockUsersGet.mockResolvedValue({ docs: [{ ref: userRef, data: () => ({ fcmTokens: ['dead-token', 'live-token'] }) }] });
    mockLocationGet.mockResolvedValue({ data: () => undefined });
    mockSendEachForMulticast.mockResolvedValue({
      failureCount: 1,
      responses: [
        { success: false, error: { code: 'messaging/registration-token-not-registered' } },
        { success: true },
      ],
    });

    await sendNewPatientAlerts.run(fakeDocumentEvent(patientData, { patientId: 'p1' }) as never);

    expect(userRef.update).toHaveBeenCalledWith({ fcmTokens: { __arrayRemove: ['dead-token'] } });
  });

  it('does not touch any user doc when a send fails for a reason other than an unregistered token', async () => {
    const userRef = { update: vi.fn() };
    mockUsersGet.mockResolvedValue({ docs: [{ ref: userRef, data: () => ({ fcmTokens: ['token-1'] }) }] });
    mockLocationGet.mockResolvedValue({ data: () => undefined });
    mockSendEachForMulticast.mockResolvedValue({
      failureCount: 1,
      responses: [{ success: false, error: { code: 'messaging/internal-error' } }],
    });

    await sendNewPatientAlerts.run(fakeDocumentEvent(patientData, { patientId: 'p1' }) as never);

    expect(userRef.update).not.toHaveBeenCalled();
  });
});
