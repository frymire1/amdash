import { test, expect } from '@playwright/test';

test('redirects to the physician view', async ({ page }) => {
  await page.goto('/');

  await expect(page).toHaveURL(/\/physician$/);
  await expect(page.locator('app-nav-bar')).toBeVisible();
});
