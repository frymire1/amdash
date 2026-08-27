import { CallableRequest } from 'firebase-functions/v2/https';

// Shared by every *.test.ts file that unit-tests an onCall callable
// directly via its own .run(request) method (a real, documented feature
// of firebase-functions v2's CallableFunction — see
// node_modules/firebase-functions/lib/v2/providers/https.d.ts — not a
// firebase-functions-test/emulator dependency). rawRequest is typed as a
// real Express Request, but none of this repo's callables ever read it —
// they only use request.data/request.auth — so a cast-through empty
// object is fine here rather than constructing a real one.
export function fakeCallableRequest<T>(data: T, uid?: string): CallableRequest<T> {
  return {
    data,
    auth: uid === undefined ? undefined : { uid, token: {} as never, rawToken: 'fake-raw-token' },
    rawRequest: {} as never,
    acceptsStreaming: false,
  };
}

// Same idea as fakeCallableRequest, for onDocumentCreated/onDocumentDeleted
// triggers (event.data?.data() is the shape these handlers actually read —
// everything else on a real QueryDocumentSnapshot is unused by this repo's
// trigger handlers). `data: undefined` simulates the "event fired with no
// snapshot" edge case each handler already guards against.
export function fakeDocumentEvent<P extends Record<string, string>>(
  data: Record<string, unknown> | undefined,
  params: P,
): { data: { data: () => Record<string, unknown> } | undefined; params: P } {
  return { data: data === undefined ? undefined : { data: () => data }, params };
}

// Same idea, for onDocumentUpdated — event.data?.before.data() /
// event.data?.after.data() is the shape onPatientUpdated actually reads.
export function fakeDocumentUpdatedEvent<P extends Record<string, string>>(
  before: Record<string, unknown> | undefined,
  after: Record<string, unknown> | undefined,
  params: P,
): {
  data: { before: { data: () => Record<string, unknown> | undefined }; after: { data: () => Record<string, unknown> | undefined } } | undefined;
  params: P;
} {
  return {
    data: before === undefined && after === undefined ? undefined : { before: { data: () => before }, after: { data: () => after } },
    params,
  };
}
