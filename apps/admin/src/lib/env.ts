export type SupabasePublicEnv = Readonly<{
  supabaseUrl: string;
  supabaseAnonKey: string;
}>;

function requiredEnvironmentValue(
  name: "NEXT_PUBLIC_SUPABASE_URL" | "NEXT_PUBLIC_SUPABASE_ANON_KEY",
  environment: NodeJS.ProcessEnv,
): string {
  const value = environment[name]?.trim();

  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }

  return value;
}

function validateSupabaseUrl(value: string): string {
  let parsedUrl: URL;

  try {
    parsedUrl = new URL(value);
  } catch {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL must be an absolute HTTP(S) URL");
  }

  if (parsedUrl.protocol !== "http:" && parsedUrl.protocol !== "https:") {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL must use HTTP(S)");
  }

  return parsedUrl.toString().replace(/\/$/, "");
}

/**
 * Returns only browser-safe Supabase settings. Service-role credentials are
 * deliberately absent from this module and must never be imported by UI code.
 */
export function getSupabasePublicEnv(
  environment: NodeJS.ProcessEnv = process.env,
): SupabasePublicEnv {
  return {
    supabaseUrl: validateSupabaseUrl(
      requiredEnvironmentValue("NEXT_PUBLIC_SUPABASE_URL", environment),
    ),
    supabaseAnonKey: requiredEnvironmentValue(
      "NEXT_PUBLIC_SUPABASE_ANON_KEY",
      environment,
    ),
  };
}
