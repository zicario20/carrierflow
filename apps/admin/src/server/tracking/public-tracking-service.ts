import "server-only";

export type PublicTrackingCurrentLocation = Readonly<{
  accuracyMeters: number;
  latitude: number;
  longitude: number;
  recordedAt: string;
}>;

export type PublicTrackingView = Readonly<{
  currentLocation: PublicTrackingCurrentLocation | null;
  eta: string | null;
  operationalStatus: string;
}>;

type RpcResponse = Readonly<{
  data: unknown | null;
  error: Readonly<{ code?: string }> | null;
}>;

/** The anonymous client may invoke only the narrow resolver RPC. */
export type PublicTrackingReadClient = Readonly<{
  rpc: (
    name: "resolve_public_load_tracking",
    arguments_: Readonly<{ token_value: string }>,
  ) => PromiseLike<RpcResponse>;
}>;

const opaqueTokenPattern = /^[0-9a-f]{64}$/;
const operationalStatuses = new Set([
  "draft",
  "scheduled",
  "assigned",
  "en_route_to_pickup",
  "arrived_pickup",
  "loading",
  "picked_up",
  "en_route_to_delivery",
  "arrived_delivery",
  "unloading",
  "delivered",
  "closed",
  "cancelled",
]);

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function parseCurrentLocation(
  value: unknown,
  now: Date,
): PublicTrackingCurrentLocation | null {
  if (typeof value !== "object" || value === null) return null;
  const row = value as Record<string, unknown>;
  const { accuracyMeters, latitude, longitude, recordedAt } = row;
  const recordedAtDate = typeof recordedAt === "string" ? new Date(recordedAt) : null;
  if (
    !isFiniteNumber(accuracyMeters) ||
    accuracyMeters < 0 ||
    accuracyMeters > 100000 ||
    !isFiniteNumber(latitude) ||
    latitude < -90 ||
    latitude > 90 ||
    !isFiniteNumber(longitude) ||
    longitude < -180 ||
    longitude > 180 ||
    typeof recordedAt !== "string" ||
    recordedAtDate === null ||
    Number.isNaN(recordedAtDate.getTime()) ||
    recordedAtDate.getTime() > now.getTime() + 5 * 60_000 ||
    now.getTime() - recordedAtDate.getTime() > 5 * 60_000
  ) {
    return null;
  }
  return { accuracyMeters, latitude, longitude, recordedAt };
}

function parsePublicTrackingView(value: unknown, now: Date): PublicTrackingView | null {
  if (typeof value !== "object" || value === null) return null;
  const row = value as Record<string, unknown>;
  const { currentLocation, eta, operationalStatus } = row;
  if (
    typeof operationalStatus !== "string" ||
    !operationalStatuses.has(operationalStatus) ||
    (typeof eta !== "string" && eta !== null) ||
    (typeof eta === "string" && Number.isNaN(new Date(eta).getTime()))
  ) {
    return null;
  }

  return {
    currentLocation: parseCurrentLocation(currentLocation, now),
    eta,
    operationalStatus,
  };
}

export function isOpaquePublicTrackingToken(value: string): boolean {
  return opaqueTokenPattern.test(value);
}

/**
 * Resolves a capability through PostgreSQL only. The parser is deliberately
 * projection-only: unexpected IDs, documents, fleet context, and link data
 * are ignored rather than passed to a browser response.
 */
export async function resolvePublicTracking({
  client,
  now = new Date(),
  token,
}: Readonly<{
  client: PublicTrackingReadClient;
  now?: Date;
  token: string;
}>): Promise<PublicTrackingView | null> {
  if (!isOpaquePublicTrackingToken(token)) return null;
  const response = await client.rpc("resolve_public_load_tracking", {
    token_value: token,
  });
  if (response.error || response.data === null) return null;
  return parsePublicTrackingView(response.data, now);
}
