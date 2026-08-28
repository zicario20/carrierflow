import "server-only";

import type { CompanyRole } from "../auth/authorize";

type AuthenticatedDispatchClient = Readonly<{
  auth: Readonly<{ getUser: () => Promise<{ data: { user: { id: string } | null } }> }>;
  from: (table: "company_memberships") => { select: (columns: string) => any };
}>;

export type AuthenticatedDispatchContext = Readonly<{
  companyId: string;
  role: Exclude<CompanyRole, "driver">;
  userId: string;
}>;

function isManagerRole(value: unknown): value is AuthenticatedDispatchContext["role"] {
  return value === "owner" || value === "admin" || value === "dispatcher";
}

/** Derives the active manager tenant from the authenticated request only. */
export async function getAuthenticatedDispatchContext(
  client: AuthenticatedDispatchClient,
): Promise<AuthenticatedDispatchContext | null> {
  const user = (await client.auth.getUser()).data.user;
  if (!user) return null;
  const response = await client
    .from("company_memberships")
    .select("company_id, role")
    .eq("user_id", user.id)
    .eq("status", "active")
    .in("role", ["owner", "admin", "dispatcher"])
    .maybeSingle();
  if (response.error || !response.data || typeof response.data !== "object") return null;
  const row = response.data as { company_id?: unknown; role?: unknown };
  return typeof row.company_id === "string" && isManagerRole(row.role)
    ? { companyId: row.company_id, role: row.role, userId: user.id }
    : null;
}
