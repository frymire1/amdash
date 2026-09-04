import { beforeEach, describe, expect, it, vi } from 'vitest';

// vi.hoisted() is required (not plain top-level consts) — see
// audit.test.ts's comment for why.
const { mockHospitalsWhere1, mockHospitalsWhere2, mockHospitalsLimit, mockHospitalsGet, mockCollection } = vi.hoisted(() => {
  const mockHospitalsGet = vi.fn();
  const mockHospitalsLimit = vi.fn(() => ({ get: mockHospitalsGet }));
  const mockHospitalsWhere2 = vi.fn(() => ({ limit: mockHospitalsLimit }));
  const mockHospitalsWhere1 = vi.fn(() => ({ where: mockHospitalsWhere2 }));

  return {
    mockHospitalsWhere1,
    mockHospitalsWhere2,
    mockHospitalsLimit,
    mockHospitalsGet,
    mockCollection: vi.fn((name: string) => {
      if (name === 'hospitals') return { where: mockHospitalsWhere1 };
      throw new Error(`Unexpected collection in test: ${name}`);
    }),
  };
});

vi.mock('firebase-admin/firestore', () => ({
  getFirestore: () => ({ collection: mockCollection }),
}));

vi.mock('firebase-functions/params', () => ({
  defineSecret: () => ({ value: () => 'fake-directions-api-key' }),
}));

import { callDirectionsApi, decodePolyline, haversineDistanceKm, resolveDestinationHospitalLatLng } from './directions';

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

describe('callDirectionsApi', () => {
  it('returns null when the Directions API reports no route (e.g. ZERO_RESULTS)', async () => {
    mockDirectionsFetchResponse({ status: 'ZERO_RESULTS', routes: [] });
    const result = await callDirectionsApi(1, 2, 3, 4);
    expect(result).toBeNull();
  });

  it('returns the decoded route, including durationSeconds, on success', async () => {
    mockDirectionsFetchResponse(OK_DIRECTIONS_RESPONSE);
    const result = await callDirectionsApi(1, 2, 3, 4);
    expect(result).toEqual({
      durationText: '12 mins',
      durationSeconds: 720,
      distanceText: '5.2 km',
      polylinePoints: [ONE_POINT_DECODED],
    });
  });
});

describe('decodePolyline', () => {
  it('decodes a positive-delta point correctly', () => {
    expect(decodePolyline(ONE_POINT_ENCODED_POLYLINE)).toEqual([ONE_POINT_DECODED]);
  });

  it("decodes a negative-delta polyline point correctly (the sign-handling branch)", () => {
    expect(decodePolyline(NEGATIVE_POINT_ENCODED_POLYLINE)).toEqual([NEGATIVE_POINT_DECODED]);
  });
});

describe('haversineDistanceKm', () => {
  it('is zero for the same point', () => {
    expect(haversineDistanceKm(43.65, -79.38, 43.65, -79.38)).toBeCloseTo(0, 6);
  });

  it('matches the well-known ~111.19km-per-degree-of-latitude figure', () => {
    // One degree of latitude is a fixed, real-world-verifiable distance
    // regardless of longitude — a good sanity check that doesn't depend on
    // trusting any one specific city-pair distance from memory.
    expect(haversineDistanceKm(0, 0, 1, 0)).toBeCloseTo(111.19, 1);
  });

  it('is symmetric (order of the two points does not matter)', () => {
    const ab = haversineDistanceKm(43.65, -79.38, 43.7, -79.5);
    const ba = haversineDistanceKm(43.7, -79.5, 43.65, -79.38);
    expect(ab).toBeCloseTo(ba, 9);
  });
});

describe('resolveDestinationHospitalLatLng', () => {
  it('returns null when no hospital matches', async () => {
    mockHospitalsGet.mockResolvedValue({ docs: [] });
    const result = await resolveDestinationHospitalLatLng('org-1', 'General Hospital');
    expect(result).toBeNull();
    expect(mockHospitalsWhere1).toHaveBeenCalledWith('organizationId', '==', 'org-1');
    expect(mockHospitalsWhere2).toHaveBeenCalledWith('name', '==', 'General Hospital');
  });

  it('returns null when the matching doc has no numeric latitude/longitude', async () => {
    mockHospitalsGet.mockResolvedValue({ docs: [{ data: () => ({}) }] });
    const result = await resolveDestinationHospitalLatLng('org-1', 'General Hospital');
    expect(result).toBeNull();
  });

  it('returns the hospital lat/lng on a match', async () => {
    mockHospitalsGet.mockResolvedValue({ docs: [{ data: () => ({ latitude: 43.7, longitude: -79.5 }) }] });
    const result = await resolveDestinationHospitalLatLng('org-1', 'General Hospital');
    expect(result).toEqual({ latitude: 43.7, longitude: -79.5 });
  });
});
