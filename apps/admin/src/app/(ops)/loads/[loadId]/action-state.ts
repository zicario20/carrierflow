import type { RouteEstimateRevision } from "../../../../server/routing/estimate-service";

export type DispatchActionState = Readonly<{
  message?: string;
  routeEstimate?: Pick<RouteEstimateRevision, "emptyMiles" | "loadedMiles" | "quoteUsd" | "quoteUsdPerTotalMile" | "totalMiles">;
  routeStatus?: "pending" | "ready";
  status: "idle" | "error" | "forbidden" | "success";
}>;
