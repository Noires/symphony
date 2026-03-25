import { test, expect } from '@playwright/test';

const routes = [
  { name: 'overview', path: '/' },
  { name: 'approvals', path: '/approvals?selected=approval-ui-1' },
  { name: 'settings', path: '/settings' },
  { name: 'runs', path: '/runs?view=history' },
  { name: 'run-detail', path: '/runs/TR-44/run-44' }
];
const screenshotOptions = { maxDiffPixels: 150 };

async function visit(page, path, theme = 'light') {
  await page.addInitScript((currentTheme) => {
    window.localStorage.setItem('symphony-theme', currentTheme);
    document.documentElement.dataset.theme = currentTheme;
  }, theme);

  await page.goto(path);
  await page.waitForLoadState('networkidle');
  await expect(page.locator('#main-content')).toBeVisible();
  await expect(page.locator('[data-theme-toggle] .utility-button-meta')).toHaveText(theme === 'dark' ? 'Dark' : 'Light');
}

test.describe('dashboard visual regressions', () => {
  for (const route of routes) {
    test(`${route.name} matches the ${route.name} baseline`, async ({ page }) => {
      await visit(page, route.path);
      await expect(page.locator('#main-content')).toHaveScreenshot(`${route.name}.png`, screenshotOptions);
    });
  }

  test('overview dark theme matches the dark baseline', async ({ page }) => {
    await visit(page, '/', 'dark');
    await expect(page.locator('#main-content')).toHaveScreenshot('overview-dark.png', screenshotOptions);
  });
});
