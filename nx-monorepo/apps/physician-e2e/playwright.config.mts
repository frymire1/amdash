import { defineConfig, devices } from '@playwright/test';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// These tests run against the real deployed dev site (not a local dev
// server) — set BASE_URL to override, e.g. for a preview channel.
const baseURL = process.env['BASE_URL'] || 'https://amdash-physician-dev.web.app';

const dirname = path.dirname(fileURLToPath(import.meta.url));
const workspaceRoot = path.resolve(dirname, '../..');

/**
 * Read environment variables from file.
 * https://github.com/motdotla/dotenv
 */
// import 'dotenv/config';

/**
 * See https://playwright.dev/docs/test-configuration.
 *
 * Generated as a .mts file so Node forces ESM regardless of workspace
 * `type`. Playwright routes `.mts` through its ESM loader (dynamic import,
 * bypassing the pirates CJS-compile path), and Nx's native TS strip loads
 * `.mts` directly. Playwright's configLoader auto-discovers
 * `playwright.config.mts` via its extension list
 * (.ts/.js/.mts/.mjs/.cts/.cjs).
 *
 * NOTE: this intentionally does NOT import `nxE2EPreset` from
 * `@nx/playwright/preset` (or `workspaceRoot` from `@nx/devkit`) — under this
 * Node/Playwright ESM config loader, requiring those crashes inside Nx's
 * native binary (`TypeError: Cannot convert undefined or null to object` in
 * `nx/dist/src/native/index.js`), even though the same modules load fine via
 * a plain CommonJS `require()`. `nxE2EPreset`'s output is inlined below
 * instead so the config only touches `@playwright/test` and Node builtins.
 */
export default defineConfig({
  testDir: './src',
  outputDir: path.join(workspaceRoot, 'dist/.playwright/apps/physician-e2e/test-output'),
  fullyParallel: true,
  forbidOnly: false,
  retries: 0,
  reporter: [
    [
      'html',
      {
        outputFolder: path.join(workspaceRoot, 'dist/.playwright/apps/physician-e2e/playwright-report'),
        open: 'on-failure',
      },
    ],
  ],
  /* Shared settings for all the projects below. See https://playwright.dev/docs/api/class-testoptions. */
  use: {
    baseURL,
    /* Collect trace when retrying the failed test. See https://playwright.dev/docs/trace-viewer */
    trace: 'on-first-retry',
  },
  // No webServer here — these tests hit the deployed amdash-dev hosting
  // sites directly (see baseURL above and EMS_ORIGIN in
  // live-tracking.spec.ts), not a locally-started dev server. Redeploy
  // before running these if you have unreleased local changes.
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },

    {
      name: 'firefox',
      use: { ...devices['Desktop Firefox'] },
    },

    {
      name: 'webkit',
      use: { ...devices['Desktop Safari'] },
    },

    // Uncomment for mobile browsers support
    /* {
      name: 'Mobile Chrome',
      use: { ...devices['Pixel 5'] },
    },
    {
      name: 'Mobile Safari',
      use: { ...devices['iPhone 12'] },
    }, */

    // Uncomment for branded browsers
    /* {
      name: 'Microsoft Edge',
      use: { ...devices['Desktop Edge'], channel: 'msedge' },
    },
    {
      name: 'Google Chrome',
      use: { ...devices['Desktop Chrome'], channel: 'chrome' },
    } */
  ],
});
