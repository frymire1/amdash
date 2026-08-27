import { defineConfig } from 'vitest/config';

// Coverage thresholds are a floor, not a target — they're set to whatever
// the real test suite currently measures (see TESTING.md for the backfill
// roadmap toward 100%), and ratchet up as more of src/ gets real tests.
// vitest fails the run outright if measured coverage drops below these,
// which is what actually makes them a CI gate rather than a report nobody
// reads.
export default defineConfig({
  test: {
    coverage: {
      provider: 'v8',
      // 'lcov' (not used here) generates a full browsable HTML report tree
      // — one file per source file, including every tiny classes/*.ts
      // interface file — which is neither needed for CI's machine-readable
      // gate nor something to litter the working tree with locally.
      // 'lcovonly' writes just the lcov.info CI actually reads.
      reporter: ['text', 'lcovonly'],
      include: ['src/**/*.ts'],
      // index.ts: pure re-export wiring — nothing here to unit test beyond
      // what tsc already guarantees (the right names are exported).
      // test-utils.ts: test infrastructure (fakeCallableRequest), not
      // production code.
      exclude: ['src/index.ts', 'src/test-utils.ts', 'src/**/*.test.ts'],
      // 100% on all four metrics, for real — the only two lines that
      // aren't unit-testable (provably unreachable defensive fallbacks;
      // see their own /* v8 ignore next */ comments in admin.ts and
      // patient-data.ts) are explicitly excluded rather than silently
      // dragging the percentage down. This is a hard floor: dropping it
      // means either a real regression or a new untested branch snuck
      // in — fix that, don't lower the number.
      thresholds: {
        lines: 100,
        functions: 100,
        branches: 100,
        statements: 100,
      },
    },
  },
});
