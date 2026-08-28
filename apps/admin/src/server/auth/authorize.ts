import { forbidden, ok, type MutationResult } from "../result";

export type CompanyRole = "owner" | "admin" | "dispatcher" | "driver";

export type AdministrativePermission =
  | "company.invitation.create"
  | "company.plan.view"
  | "company.privacy.retention.run"
  | "fleet.driver.manage"
  | "fleet.vehicle.manage"
  | "fleet.assignment.manage";

export type AuthorizeInput = Readonly<{
  role: CompanyRole;
  permission: AdministrativePermission;
}>;

function hasPermission(
  role: CompanyRole,
  permission: AdministrativePermission,
): boolean {
  switch (role) {
    case "owner":
      return true;
    case "admin":
    case "dispatcher":
      return permission.startsWith("fleet.");
    case "driver":
      return false;
  }
}

export function authorize(
  input: AuthorizeInput,
): MutationResult<Readonly<{ permission: AdministrativePermission }>> {
  if (!hasPermission(input.role, input.permission)) {
    return forbidden();
  }

  return ok({ permission: input.permission });
}
