// Firestore's client SDK never rejects a write blocked by a dropped
// connection — without offline persistence enabled (none of this repo's
// apps configure it), a blocked write's promise just stays pending,
// retrying indefinitely, until connectivity returns. Left alone, a caller
// awaiting that promise (and showing a "Saving…" spinner in the meantime)
// would spin forever with no way for the user to know something's wrong.
// This races the real operation against a timer so the caller can bound how
// long it waits before surfacing an error — it does NOT cancel the
// underlying write, which may still complete in the background afterward.
export class TimeoutError extends Error {
  constructor() {
    super('Timed out waiting for a response.');
    this.name = 'TimeoutError';
  }
}

export function withTimeout<T>(promise: Promise<T>, timeoutMs = 15000): Promise<T> {
  return Promise.race([
    promise,
    new Promise<never>((_, reject) => {
      setTimeout(() => reject(new TimeoutError()), timeoutMs);
    }),
  ]);
}
