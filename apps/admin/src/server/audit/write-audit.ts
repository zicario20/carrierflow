import "server-only";

import { authorize, type CompanyRole } from "../auth/authorize";
import {
  forbidden,
  ok,
  validationError,
  type MutationResult,
} from "../result";

type InvitationRpcArguments = Readonly<{
  target_company_id: string;
  invitee_email: string;
  invitee_role: CompanyRole;
}>;

type InvitationRpcRow = Readonly<{
  id: string;
  company_id: string;
  invited_email: string | null;
  role: CompanyRole;
  status: "pending" | "active" | "suspended" | "disabled";
}>;

type RpcError = Readonly<{
  code?: string;
}>;

/**
 * The caller must supply an RLS-bound server client created from the current
 * request. This narrow interface deliberately has no service-role credential
 * or direct table mutation capability.
 */
export type TrustedSupabaseServerClient = Readonly<{
  rpc: (
    functionName: "create_company_invitation",
    arguments_: InvitationRpcArguments,
  ) => Promise<Readonly<{ data: InvitationRpcRow | null; error: RpcError | null }>>;
}>;

export type CreateCompanyInvitationInput = Readonly<{
  client: TrustedSupabaseServerClient;
  /** Derived by trusted server code; database authorization remains final. */
  actorRole: CompanyRole;
  companyId: string;
  email: string;
  role: CompanyRole;
}>;

export type CompanyInvitation = Readonly<{
  id: string;
  companyId: string;
  email: string;
  role: CompanyRole;
  status: "pending";
}>;

/**
 * Creates an invitation through the database RPC. The RPC inserts the pending
 * membership and its audit event inside one database transaction.
 */
export async function createCompanyInvitation(
  input: CreateCompanyInvitationInput,
): Promise<MutationResult<CompanyInvitation>> {
  const authorization = authorize({
    role: input.actorRole,
    permission: "company.invitation.create",
  });

  if (!authorization.ok) {
    return authorization;
  }

  const response = await input.client.rpc("create_company_invitation", {
    target_company_id: input.companyId,
    invitee_email: input.email,
    invitee_role: input.role,
  });

  if (response.error?.code === "42501") {
    return forbidden();
  }

  if (response.error) {
    return validationError("The invitation could not be created.", "email");
  }

  if (!response.data || response.data.status !== "pending" || !response.data.invited_email) {
    return validationError("The invitation could not be created.");
  }

  return ok({
    id: response.data.id,
    companyId: response.data.company_id,
    email: response.data.invited_email,
    role: response.data.role,
    status: "pending",
  });
}
