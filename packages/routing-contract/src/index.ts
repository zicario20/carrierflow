/**
 * A routing boundary contains operational geometry and distance estimates only.
 * It deliberately has no API-key, credential, driver-pay, broker-revenue, or
 * margin fields: provider credentials remain in server configuration.
 */
export type DecimalString = string;

export type RoutePoint = Readonly<{
  id: string;
  label: string;
  latitude: number;
  longitude: number;
}>;

export type RoutePurpose = "empty" | "loaded";

export type RouteRequest = Readonly<{
  purpose: RoutePurpose;
  waypoints: readonly RoutePoint[];
}>;

export type RouteLegEstimate = Readonly<{
  /** A non-negative decimal string in miles; never a floating-point currency value. */
  miles: DecimalString;
  /** Provider response stripped of credentials before persistence. */
  routeData: Readonly<Record<string, unknown>>;
}>;

/** Replaceable, server-owned routing adapter. It does not claim truck-safe routing. */
export type RoutingProvider = Readonly<{
  name: string;
  estimateRoute: (
    request: RouteRequest,
    options?: Readonly<{ signal: AbortSignal }>,
  ) => Promise<RouteLegEstimate>;
}>;

export const emptyOriginKinds = [
  "active_load_final_stop",
  "last_accepted_location",
  "declared_base",
] as const;

export type EmptyOriginKind = (typeof emptyOriginKinds)[number];

export const routeEstimateInvalidationReasons = [
  "initial",
  "active_final_stop_changed",
  "driver_changed",
  "assignment_changed",
] as const;

export type RouteEstimateInvalidationReason =
  (typeof routeEstimateInvalidationReasons)[number];
