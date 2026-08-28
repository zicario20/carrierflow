import { describe, expect, test } from "vitest";

import { getSupabaseServiceEnv } from "../src/lib/supabase/service";

describe("server-only Supabase service environment", () => {
  test("requires a private service-role key and does not reuse browser configuration", () => {
    expect(() =>
      getSupabaseServiceEnv({
        NEXT_PUBLIC_SUPABASE_URL: "https://example.test",
        NEXT_PUBLIC_SUPABASE_ANON_KEY: "browser-key",
        SUPABASE_URL: "https://supabase.internal.test",
      }),
    ).toThrow("SUPABASE_SERVICE_ROLE_KEY");

    expect(
      getSupabaseServiceEnv({
        SUPABASE_SERVICE_ROLE_KEY: "server-only-key",
        SUPABASE_URL: "https://supabase.internal.test",
      }),
    ).toEqual({
      supabaseUrl: "https://supabase.internal.test",
      serviceRoleKey: "server-only-key",
    });
  });
});
