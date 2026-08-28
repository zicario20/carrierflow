import { describe, expect, test } from "vitest";

import { resolveAdminLocale } from "../src/i18n/locale";

describe("resolveAdminLocale", () => {
  test.each([
    ["es-MX,es;q=0.9,en;q=0.8", "es"],
    ["ES;q=0.9,en;q=0.8", "es"],
    ["fr-CA,es;q=0.7", "es"],
    ["en-US,en;q=0.9,es;q=0.8", "en"],
    ["es;q=0,en;q=0.9", "en"],
    ["fr-CA;q=0.9", "en"],
    [undefined, "en"],
  ] as const)("returns %s for %s", (acceptLanguage, expectedLocale) => {
    expect(resolveAdminLocale(acceptLanguage)).toBe(expectedLocale);
  });
});
