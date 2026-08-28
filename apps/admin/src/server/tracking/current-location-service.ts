import "server-only";

export type AuthorizedCurrentLocation = Readonly<{
  accuracyMeters: number;
  driverLabel: string;
  freshness: "current";
  latitude: number;
  loadNumber: string | null;
  longitude: number;
  operationalStatus: string | null;
  recordedAt: string;
}>;

type RpcResponse = Readonly<{
  data: unknown | null;
  error: Readonly<{ code?: string }> | null;
}>;

/** An authenticated request client only; it has no service credential or table API. */
export type CurrentLocationReadClient = Readonly<{
  rpc: (
    name: "get_authorized_current_driver_location",
    arguments_: Readonly<{ target_company_id: string }>,
  ) => Promise<RpcResponse>;
}>;

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function parseCurrentLocation(
  value: unknown,
  now: Date,
): AuthorizedCurrentLocation | null {
  if (typeof value !== "object" || value === null) return null;
  const row = value as Record<string, unknown>;
  const {
    accuracyMeters,
    driverLabel,
    latitude,
    loadNumber,
    longitude,
    operationalStatus,
    recordedAt,
  } = row;
  if (typeof recordedAt !== "string") return null;
  const recordedAtDate = new Date(recordedAt);
  if (
    !isFiniteNumber(accuracyMeters) ||
    accuracyMeters < 0 ||
    accuracyMeters > 100000 ||
    typeof driverLabel !== "string" ||
    driverLabel.trim().length === 0 ||
    !isFiniteNumber(latitude) ||
    latitude < -90 ||
    latitude > 90 ||
    !isFiniteNumber(longitude) ||
    longitude < -180 ||
    longitude > 180 ||
    (typeof loadNumber !== "string" && loadNumber !== null) ||
    (typeof operationalStatus !== "string" && operationalStatus !== null) ||
    Number.isNaN(recordedAtDate.getTime()) ||
    recordedAtDate.getTime() > now.getTime() + 5 * 60_000 ||
    now.getTime() - recordedAtDate.getTime() > 5 * 60_000
  ) {
    return null;
  }

  return {
    accuracyMeters,
    driverLabel,
    freshness: "current",
    latitude,
    loadNumber,
    longitude,
    operationalStatus,
    recordedAt,
  };
}

/**
 * Exposes exactly one fresh current point already authorized by PostgreSQL.
 * It never selects history, subscribes to realtime, or turns a company
 * selector into authority: the database rechecks the authenticated manager
 * membership. The local parser fails closed if a stale payload appears.
 */
export async function getAuthorizedCurrentLocation({
  client,
  companyId,
  now = new Date(),
}: Readonly<{
  client: CurrentLocationReadClient;
  companyId: string;
  now?: Date;
}>): Promise<AuthorizedCurrentLocation | null> {
  if (!companyId) return null;
  const response = await client.rpc("get_authorized_current_driver_location", {
    target_company_id: companyId,
  });
  if (response.error || response.data === null) return null;
  return parseCurrentLocation(response.data, now);
}
