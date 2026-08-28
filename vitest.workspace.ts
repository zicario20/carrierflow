import { defineWorkspace } from "vitest/config";

export default defineWorkspace([
  {
    test: {
      exclude: ["**/blueprints/**", "**/node_modules/**", "**/dist/**"],
    },
  },
  "apps/admin/vitest.config.ts",
  "packages/*/vitest.config.ts",
]);
