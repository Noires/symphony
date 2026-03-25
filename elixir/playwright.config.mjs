import { defineConfig, devices } from '@playwright/test';

const port = Number(process.env.UI_VISUAL_PORT || 4101);
const command =
  process.platform === 'win32'
    ? `set UI_VISUAL_PORT=${port}&& mise exec -- mix run --no-halt scripts/ui_visual_server.exs`
    : `UI_VISUAL_PORT=${port} mise exec -- mix run --no-halt scripts/ui_visual_server.exs`;

export default defineConfig({
  testDir: './ui-visual',
  fullyParallel: true,
  reporter: [['list'], ['html', { open: 'never' }]],
  timeout: 60_000,
  expect: {
    timeout: 15_000,
    toHaveScreenshot: {
      animations: 'disabled',
      caret: 'hide'
    }
  },
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    trace: 'on-first-retry'
  },
  webServer: {
    command,
    cwd: '.',
    url: `http://127.0.0.1:${port}/`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000
  },
  snapshotPathTemplate: '{testDir}/{testFilePath}-snapshots/{arg}-{projectName}{ext}',
  projects: [
    {
      name: 'desktop',
      use: {
        browserName: 'chromium',
        ...devices['Desktop Chrome'],
        viewport: { width: 1440, height: 1600 }
      }
    },
    {
      name: 'tablet',
      use: {
        browserName: 'chromium',
        ...devices['iPad Pro 11'],
        viewport: { width: 1024, height: 1400 }
      }
    },
    {
      name: 'mobile',
      use: {
        browserName: 'chromium',
        ...devices['iPhone 13'],
        viewport: { width: 390, height: 1400 }
      }
    }
  ]
});
