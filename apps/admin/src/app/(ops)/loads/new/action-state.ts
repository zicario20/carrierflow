import type { RouteEstimateRevision } from "../../../../server/routing/estimate-service";

export type ProposalActionState = Readonly<{
  field?: string;
  loadId?: string;
  message?: string;
  routeStatus?: "assignment_required" | "pending" | "ready";
  routeEstimate?: Pick<RouteEstimateRevision, "emptyMiles" | "loadedMiles" | "quoteUsd" | "quoteUsdPerTotalMile" | "totalMiles">;
  status: "idle" | "error" | "forbidden" | "pending" | "success";
}>;

export const initialProposalActionState: ProposalActionState = { status: "idle" };
