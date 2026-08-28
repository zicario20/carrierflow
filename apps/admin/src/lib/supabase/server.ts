import "server-only";

import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

import { getSupabasePublicEnv } from "../env";

/**
 * Creates an RLS-bound client for an App Router server request. This module
 * uses only the publishable anon key; privileged service credentials stay in
 * server-only mutation boundaries created in later tasks.
 */
export async function createSupabaseServerClient() {
  const cookieStore = await cookies();
  const { supabaseAnonKey, supabaseUrl } = getSupabasePublicEnv();

  return createServerClient(supabaseUrl, supabaseAnonKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          for (const cookie of cookiesToSet) {
            cookieStore.set(cookie.name, cookie.value, cookie.options);
          }
        } catch {
          // Server Components cannot write cookies. Middleware/route handlers
          // refresh session cookies when a write-capable response is available.
        }
      },
    },
  });
}
