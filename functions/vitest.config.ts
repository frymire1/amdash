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
      // Pure re-export wiring — nothing here to unit test beyond what tsc
      // already guarantees (the right names are exported).
      exclude: ['src/index.ts', 'src/**/*.test.ts'],
      // Current real numbers (kms.ts + audit.ts + fhir.ts fully covered;
      // admin.ts/patients.ts/physician.ts/ems.ts/shared.ts/email.ts not
      // yet — see TESTING.md's backfill roadmap), floored slightly below
      // the exact measured value so a harmless rounding difference between
      // Node/v8 versions doesn't flake CI.
      thresholds: {
        lines: 16,
        functions: 20,
        branches: 16,
        statements: 17,
      },
    },
  },
});
