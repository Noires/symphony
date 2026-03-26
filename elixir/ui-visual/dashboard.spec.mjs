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

  test('settings disclosures reveal editors without layout overlap', async ({ page }) => {
    await visit(page, '/settings');

    await page.locator('.settings-group-panel > summary').first().click();
    await page.locator('.setting-disclosure > summary').first().click();

    await expect(
      page
        .locator('.setting-disclosure[open] .field-input, .setting-disclosure[open] .field-select, .setting-disclosure[open] .field-textarea')
        .first()
    ).toBeVisible();
  });

  test('approval workbench disclosures can expand', async ({ page }) => {
    await visit(page, '/approvals?selected=approval-ui-1');

    await page.locator('.disclosure-panel > summary').filter({ hasText: 'Raw approval details' }).click();
    await expect(page.locator('.disclosure-panel[open] .code-panel').first()).toBeVisible();
  });

  test('run detail disclosures can expand and stay scrollable', async ({ page }) => {
    await visit(page, '/runs/TR-44/run-44');

    await page.locator('.section-frame-collapsible > summary').filter({ hasText: 'Diff preview' }).focus();
    await page.keyboard.press('Enter');
    await expect(page.locator('.section-frame-collapsible[open] .code-panel').first()).toBeVisible();
  });
});
