import "server-only";

import { authorize, type CompanyRole } from "../auth/authorize";
import { forbidden, ok, validationError, type MutationResult } from "../result";

export type PilotPlanCode = "starter" | "growth" | "scale";
export type PilotTrialState = "active" | "expired";

export type PilotEntitlement = Readonly<{
  activeDriverCount: number;
  availableDriverSlots: number;
  driverCapacity: number;
  monthlyPriceUsd: number;
  planCode: PilotPlanCode;
  trialEndsAt: string;
  trialStartedAt: string;
  trialState: PilotTrialState;
}>;

type RpcResponse = Readonly<{
  data: unknown | null;
  error: Readonly<{ code?: string }> | null;
}>;

/** Authenticated request client only; it deliberately has no service credential or table writes. */
export type PilotEntitlementReadClient = Readonly<{
  rpc: (
    name: "get_company_pilot_entitlement",
    arguments_: Readonly<{ target_company_id: string }>,
  ) => Promise<RpcResponse>;
}>;

const planTerms: Readonly<Record<PilotPlanCode, Readonly<{ capacity: number; monthlyPriceUsd: number }>>> = {
  starter: { capacity: 10, monthlyPriceUsd: 20 },
  growth: { capacity: 25, monthlyPriceUsd: 40 },
  scale: { capacity: 60, monthlyPriceUsd: 60 },
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

function isPlanCode(value: unknown): value is PilotPlanCode {
  return value === "starter" || value === "growth" || value === "scale";
}

function isTrialState(value: unknown): value is PilotTrialState {
  return value === "active" || value === "expired";
}

function parseEntitlement(value: unknown): PilotEntitlement | null {
  if (!isRecord(value)) return null;
  const {
    activeDriverCount,
    availableDriverSlots,
    driverCapacity,
    monthlyPriceUsd,
    planCode,
    trialEndsAt,
    trialStartedAt,
    trialState,
  } = value;
  if (
    !isNonNegativeInteger(activeDriverCount) ||
    !isNonNegativeInteger(availableDriverSlots) ||
    !isNonNegativeInteger(driverCapacity) ||
    !isNonNegativeInteger(monthlyPriceUsd) ||
    !isPlanCode(planCode) ||
    !isTrialState(trialState) ||
    typeof trialEndsAt !== "string" ||
    typeof trialStartedAt !== "string"
  ) return null;

  const terms = planTerms[planCode];
  const trialStart = new Date(trialStartedAt);
  const trialEnd = new Date(trialEndsAt);
  if (
    driverCapacity !== terms.capacity ||
    monthlyPriceUsd !== terms.monthlyPriceUsd ||
    activeDriverCount > driverCapacity ||
    availableDriverSlots !== driverCapacity - activeDriverCount ||
    Number.isNaN(trialStart.getTime()) ||
    Number.isNaN(trialEnd.getTime()) ||
    trialEnd.getTime() - trialStart.getTime() !== 7 * 24 * 60 * 60 * 1000
  ) return null;

  return {
    activeDriverCount,
    availableDriverSlots,
    driverCapacity,
    monthlyPriceUsd,
    planCode,
    trialEndsAt,
    trialStartedAt,
    trialState,
  };
}

/** Reads only the server-authorized owner view; plan changes and checkout are out of pilot scope. */
export async function getPilotEntitlement(input: Readonly<{
  actorRole: CompanyRole;
  client: PilotEntitlementReadClient;
  companyId: string;
}>): Promise<MutationResult<PilotEntitlement>> {
  const authorization = authorize({ permission: "company.plan.view", role: input.actorRole });
  if (!authorization.ok) return authorization;
  if (!input.companyId) return validationError("Pilot plan settings could not be loaded.");

  const response = await input.client.rpc("get_company_pilot_entitlement", {
    target_company_id: input.companyId,
  });
  if (response.error?.code === "42501") return forbidden();
  if (response.error || response.data === null) {
    return validationError("Pilot plan settings could not be loaded.");
  }
  const entitlement = parseEntitlement(response.data);
  return entitlement ? ok(entitlement) : validationError("Pilot plan settings could not be loaded.");
}
