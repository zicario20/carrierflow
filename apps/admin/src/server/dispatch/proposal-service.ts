import "server-only";

import { ok, validationError, type MutationResult } from "../result";
import type { RouteEstimateRevision } from "../routing/estimate-service";

type CreateLoadClient = Readonly<{
  rpc: (name: "create_load_proposal", args: Record<string, unknown>) => Promise<Readonly<{ data: unknown | null; error: Readonly<{ code?: string }> | null }>>;
}>;

export type LoadProposalInput = Readonly<{
  delivery: string;
  loadNumber: string;
  pickup: string;
  quoteUsd: string;
}>;

export type ProposalSubmission = Readonly<{
  loadId: string;
  revision: RouteEstimateRevision | null;
  routeStatus: "assignment_required";
}>;

function parseLoadId(value: unknown): string | null {
  return value && typeof value === "object" && typeof (value as { id?: unknown }).id === "string"
    ? (value as { id: string }).id
    : null;
}

function validate(input: LoadProposalInput): MutationResult<LoadProposalInput> {
  if (!input.loadNumber.trim()) return validationError("A load number is required.", "loadNumber");
  if (!input.pickup.trim()) return validationError("A pickup stop is required.", "pickup");
  if (!input.delivery.trim()) return validationError("A delivery stop is required.", "delivery");
  if (!/^\d+(?:\.\d{1,2})?$/.test(input.quoteUsd) || Number(input.quoteUsd) <= 0) return validationError("A positive quoted USD amount is required.", "quoteUsd");
  return ok({ ...input, delivery: input.delivery.trim(), loadNumber: input.loadNumber.trim(), pickup: input.pickup.trim(), quoteUsd: input.quoteUsd });
}

/** The browser sends only proposal data. The DB derives all route context. */
export async function submitAuthorizedLoadProposal(input: Readonly<{
  client: CreateLoadClient;
  companyId: string;
  intentKey: string;
  proposal: LoadProposalInput;
}>): Promise<MutationResult<ProposalSubmission>> {
  const proposal = validate(input.proposal);
  if (!proposal.ok) return proposal;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(input.intentKey)) {
    return validationError("A valid proposal intent key is required.", "intentKey");
  }
  const created = await input.client.rpc("create_load_proposal", {
    target_company_id: input.companyId,
    proposal_intent_key: input.intentKey,
    proposal_load_number: proposal.data.loadNumber,
    pickup_stop: { address: proposal.data.pickup, country: "US", timezone: "America/Chicago" },
    delivery_stop: { address: proposal.data.delivery, country: "US", timezone: "America/Chicago" },
    proposal_quote_usd: proposal.data.quoteUsd,
  });
  if (created.error?.code === "42501") return { ok: false, error: { code: "forbidden", message: "You do not have permission to perform this action." } };
  const loadId = created.error ? null : parseLoadId(created.data);
  if (!loadId) return validationError("The load proposal could not be created safely.", "proposal");
  return ok({ loadId, revision: null, routeStatus: "assignment_required" });
}
