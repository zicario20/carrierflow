import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    passWithNoTests: true,
    projects: [
      {
        test: {
          exclude: ["tests/**", "**/blueprints/**", "**/node_modules/**", "**/dist/**"],
          passWithNoTests: true,
        },
      },
      "apps/*/vitest.config.ts",
      "packages/*/vitest.config.ts",
    ],
  },
});
