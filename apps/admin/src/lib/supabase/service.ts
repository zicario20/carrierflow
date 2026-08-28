import "server-only";

import { createClient } from "@supabase/supabase-js";

export type SupabaseServiceEnv = Readonly<{
  supabaseUrl: string;
  serviceRoleKey: string;
}>;

type ServerEnvironment = Readonly<Record<string, string | undefined>>;

/**
 * Reads a service-role credential only in server-only code. This module never
 * reuses `NEXT_PUBLIC_*` browser settings as a credential fallback and does
 * not log or return the key through an HTTP route.
 */
export function getSupabaseServiceEnv(
  environment: ServerEnvironment = process.env,
): SupabaseServiceEnv {
  const supabaseUrl = environment.SUPABASE_URL?.trim();
  const serviceRoleKey = environment.SUPABASE_SERVICE_ROLE_KEY?.trim();
  if (!supabaseUrl) throw new Error("Missing required environment variable: SUPABASE_URL");
  if (!serviceRoleKey) {
    throw new Error("Missing required environment variable: SUPABASE_SERVICE_ROLE_KEY");
  }

  let parsedUrl: URL;
  try {
    parsedUrl = new URL(supabaseUrl);
  } catch {
    throw new Error("SUPABASE_URL must be an absolute HTTP(S) URL");
  }
  if (parsedUrl.protocol !== "http:" && parsedUrl.protocol !== "https:") {
    throw new Error("SUPABASE_URL must use HTTP(S)");
  }
  return {
    supabaseUrl: parsedUrl.toString().replace(/\/$/, ""),
    serviceRoleKey,
  };
}

/**
 * Used only by a server worker that calls service-role-only push-delivery RPCs.
 * It cannot be imported into browser modules because of `server-only` above.
 */
export function createSupabaseServiceClient(
  environment: ServerEnvironment = process.env,
) {
  const { serviceRoleKey, supabaseUrl } = getSupabaseServiceEnv(environment);
  return createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
  });
}
