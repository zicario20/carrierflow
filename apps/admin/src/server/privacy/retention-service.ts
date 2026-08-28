import "server-only";

import { authorize, type CompanyRole } from "../auth/authorize";
import { forbidden, ok, validationError, type MutationResult } from "../result";

export type PilotPrivacyRetentionSummary = Readonly<{
  policyVersion: "pilot-v1";
  preservedEvidenceMetadataCount: number;
  purgedCurrentLocationCount: number;
  purgedDetailedLocationCount: number;
}>;

type RpcResponse = Readonly<{
  data: unknown | null;
  error: Readonly<{ code?: string }> | null;
}>;

/** Authenticated request client only; the database derives the owner and tenant. */
export type PilotRetentionClient = Readonly<{
  rpc: (
    name: "run_pilot_privacy_retention",
    arguments_: Readonly<{ target_company_id: string }>,
  ) => Promise<RpcResponse>;
}>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isCount(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0;
}

function parseSummary(value: unknown): PilotPrivacyRetentionSummary | null {
  if (!isRecord(value)) return null;
  const {
    policyVersion,
    preservedEvidenceMetadataCount,
    purgedCurrentLocationCount,
    purgedDetailedLocationCount,
  } = value;
  if (
    policyVersion !== "pilot-v1" ||
    !isCount(preservedEvidenceMetadataCount) ||
    !isCount(purgedCurrentLocationCount) ||
    !isCount(purgedDetailedLocationCount)
  ) return null;
  return {
    policyVersion,
    preservedEvidenceMetadataCount,
    purgedCurrentLocationCount,
    purgedDetailedLocationCount,
  };
}

/** Executes no document retention: evidence remains legal/auditable and only count metadata returns. */
export async function runPilotPrivacyRetention(input: Readonly<{
  actorRole: CompanyRole;
  client: PilotRetentionClient;
  companyId: string;
}>): Promise<MutationResult<PilotPrivacyRetentionSummary>> {
  const authorization = authorize({ permission: "company.privacy.retention.run", role: input.actorRole });
  if (!authorization.ok) return authorization;
  if (!input.companyId) return validationError("Pilot privacy retention could not be run.");

  const response = await input.client.rpc("run_pilot_privacy_retention", {
    target_company_id: input.companyId,
  });
  if (response.error?.code === "42501") return forbidden();
  if (response.error || response.data === null) {
    return validationError("Pilot privacy retention could not be run.");
  }
  const summary = parseSummary(response.data);
  return summary ? ok(summary) : validationError("Pilot privacy retention could not be run.");
}
