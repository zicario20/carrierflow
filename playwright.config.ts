import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  testIgnore: ["**/blueprints/**"],
  outputDir: "test-results",
  reporter: "list",
  use: {
    baseURL: "http://127.0.0.1:3000",
    trace: "retain-on-failure",
  },
  webServer: {
    command: "pnpm --filter @carrierflow/admin start",
    env: {
      NEXT_PUBLIC_SUPABASE_ANON_KEY: "e2e-anon-key",
      NEXT_PUBLIC_SUPABASE_URL: "http://127.0.0.1:65535",
    },
    url: "http://127.0.0.1:3000",
    reuseExistingServer: !process.env.CI,
    timeout: 120000,
  },
});
