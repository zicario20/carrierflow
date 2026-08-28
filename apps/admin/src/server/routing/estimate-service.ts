import "server-only";

import type { RoutePoint } from "@carrierflow/routing-contract/index";

import {
  forbidden,
  ok,
  validationError,
  type MutationResult,
} from "../result";
import type { ServerRoutingProvider } from "./routing-provider";

type RpcError = Readonly<{ code?: string }>;

type ClaimRouteEstimateJobArguments = Readonly<{
  idempotency_key: string;
  target_company_id: string;
  target_job_id: string;
}>;

type RequestInitialRouteEstimateArguments = Readonly<{
  idempotency_key: string;
  quoted_amount_usd: string;
  target_company_id: string;
  target_load_id: string;
}>;

type CompleteRouteEstimateJobArguments = Readonly<{
  calculated_empty_miles: string;
  calculated_loaded_miles: string;
  context_fingerprint: string;
  expected_context_version: number;
  idempotency_key: string;
  provider_name: string;
  provider_route_summary: RouteSummary;
  target_company_id: string;
  target_job_id: string;
}>;

type RouteEstimateRpcRow = Readonly<{
  id: string;
  company_id: string;
  revision_number: number;
  empty_miles: string;
  loaded_miles: string;
  total_miles: string;
  quote_usd: string;
  quote_usd_per_total_mile: string;
}>;

type ClaimedRouteEstimateJob = Readonly<{
  id: string;
  company_id: string;
  load_id: string;
  context_version: number;
  context_fingerprint: string;
  quote_usd: string;
  empty_origin_kind: "active_load_final_stop" | "last_accepted_location" | "declared_base";
  empty_origin: RoutePoint;
  planned_stops: readonly RoutePoint[];
}>;

export type TrustedRouteEstimateClient = Readonly<{
  rpc: (
    functionName: "claim_route_estimate_recompute_job" | "complete_route_estimate_recompute_job"
      | "release_route_estimate_recompute_job" | "request_initial_route_estimate",
    arguments_: ClaimRouteEstimateJobArguments | CompleteRouteEstimateJobArguments | RequestInitialRouteEstimateArguments,
  ) => Promise<Readonly<{ data: unknown | null; error: RpcError | null }>>;
}>;

export type RouteEstimateRevision = Readonly<{
  id: string;
  companyId: string;
  revisionNumber: number;
  emptyMiles: string;
  loadedMiles: string;
  totalMiles: string;
  quoteUsd: string;
  quoteUsdPerTotalMile: string;
}>;

export type ProcessRouteEstimateJobInput = Readonly<{
  client: TrustedRouteEstimateClient;
  companyId: string;
  idempotencyKey: string;
  jobId: string;
  routingProvider: ServerRoutingProvider;
  timeoutMs?: number;
}>;

export type RequestInitialRouteEstimateInput = Readonly<{
  client: TrustedRouteEstimateClient;
  companyId: string;
  idempotencyKey: string;
  loadId: string;
  quoteUsd: string;
}>;

export type RouteEstimateJob = Readonly<{
  contextFingerprint: string;
  id: string;
  loadId: string;
  quoteUsd: string;
}>;

export type RouteSummaryItem = Readonly<{
  distanceMeters?: number;
  durationSeconds?: number;
}>;

export type RouteSummary = Readonly<{
  empty: RouteSummaryItem;
  loaded: RouteSummaryItem;
}>;

const moneyPattern = /^(?:0|[1-9]\d*)(?:\.\d{1,2})?$/;
const milesPattern = /^(?:0|[1-9]\d*)(?:\.\d{1,3})?$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const maximumStops = 16;
const maximumProviderSummaryBytes = 8_192;
const defaultProviderTimeoutMs = 10_000;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isPoint(value: unknown): value is RoutePoint {
  return isRecord(value)
    && typeof value.id === "string"
    && typeof value.label === "string"
    && typeof value.latitude === "number"
    && Number.isFinite(value.latitude)
    && value.latitude >= -90
    && value.latitude <= 90
    && typeof value.longitude === "number"
    && Number.isFinite(value.longitude)
    && value.longitude >= -180
    && value.longitude <= 180
    && value.id.trim().length > 0
    && value.id.length <= 128
    && value.label.trim().length > 0
    && value.label.length <= 160;
}

function isPositiveDecimal(value: string, pattern: RegExp): boolean {
  if (!pattern.test(value)) {
    return false;
  }
  const [whole, fraction = ""] = value.split(".");
  return BigInt(`${whole}${fraction}`) > 0n;
}

function isNonNegativeMiles(value: string): boolean {
  return milesPattern.test(value);
}

function parseClaimedJob(value: unknown): ClaimedRouteEstimateJob | null {
  if (!isRecord(value) || !Array.isArray(value.planned_stops)) {
    return null;
  }
  const { context_fingerprint, context_version, company_id, empty_origin, empty_origin_kind, id, load_id, quote_usd } = value;
  if (
    typeof id !== "string"
    || typeof company_id !== "string"
    || typeof load_id !== "string"
    || typeof context_fingerprint !== "string"
    || context_fingerprint.length < 16
    || context_fingerprint.length > 128
    || typeof context_version !== "number"
    || !Number.isInteger(context_version)
    || context_version < 1
    || typeof quote_usd !== "string"
    || !isPositiveDecimal(quote_usd, moneyPattern)
    || (empty_origin_kind !== "active_load_final_stop"
      && empty_origin_kind !== "last_accepted_location"
      && empty_origin_kind !== "declared_base")
    || !isPoint(empty_origin)
    || value.planned_stops.length < 2
    || value.planned_stops.length > maximumStops
    || !value.planned_stops.every(isPoint)
  ) {
    return null;
  }

  return {
    id,
    company_id,
    load_id,
    context_fingerprint,
    context_version,
    empty_origin_kind,
    empty_origin,
    planned_stops: value.planned_stops,
    quote_usd,
  };
}

export function parseRouteEstimateRevision(value: unknown): RouteEstimateRevision | null {
  if (!isRecord(value)) {
    return null;
  }
  const row = value as Partial<RouteEstimateRpcRow>;
  if (
    typeof row.id !== "string"
    || typeof row.company_id !== "string"
    || typeof row.revision_number !== "number"
    || !Number.isInteger(row.revision_number)
    || !isNonNegativeMiles(row.empty_miles ?? "")
    || !isPositiveDecimal(row.loaded_miles ?? "", milesPattern)
    || !isPositiveDecimal(row.total_miles ?? "", milesPattern)
    || !isPositiveDecimal(row.quote_usd ?? "", moneyPattern)
    || !isPositiveDecimal(row.quote_usd_per_total_mile ?? "", /^\d+(?:\.\d+)?$/)
  ) {
    return null;
  }
  return {
    id: row.id,
    companyId: row.company_id,
    revisionNumber: row.revision_number,
    emptyMiles: row.empty_miles ?? "",
    loadedMiles: row.loaded_miles ?? "",
    totalMiles: row.total_miles ?? "",
    quoteUsd: row.quote_usd ?? "",
    quoteUsdPerTotalMile: row.quote_usd_per_total_mile ?? "",
  };
}

function parseCompletedJob(value: unknown): RouteEstimateRevision | null {
  if (!isRecord(value) || value.status !== "completed") {
    return null;
  }
  return parseRouteEstimateRevision(value.revision);
}

function parseRouteEstimateJob(value: unknown): RouteEstimateJob | null {
  if (!isRecord(value)) {
    return null;
  }
  const { context_fingerprint, id, load_id, quote_usd } = value;
  if (
    typeof context_fingerprint !== "string"
    || context_fingerprint.length < 16
    || context_fingerprint.length > 128
    || typeof id !== "string"
    || !uuidPattern.test(id)
    || typeof load_id !== "string"
    || !uuidPattern.test(load_id)
    || typeof quote_usd !== "string"
    || !isPositiveDecimal(quote_usd, moneyPattern)
  ) {
    return null;
  }
  return {
    contextFingerprint: context_fingerprint,
    id,
    loadId: load_id,
    quoteUsd: quote_usd,
  };
}

function sanitizeRouteSummary(value: unknown): RouteSummaryItem | null {
  if (!isRecord(value)) {
    return null;
  }
  const serialized = JSON.stringify(value);
  if (new TextEncoder().encode(serialized).byteLength > maximumProviderSummaryBytes) {
    return null;
  }

  const summary: { distanceMeters?: number; durationSeconds?: number } = {};
  if (typeof value.distanceMeters === "number") {
    if (!Number.isFinite(value.distanceMeters) || value.distanceMeters < 0 || value.distanceMeters > 5_000_000) {
      return null;
    }
    summary.distanceMeters = Math.round(value.distanceMeters);
  }
  if (typeof value.durationSeconds === "number") {
    if (!Number.isFinite(value.durationSeconds) || value.durationSeconds < 0 || value.durationSeconds > 604_800) {
      return null;
    }
    summary.durationSeconds = Math.round(value.durationSeconds);
  }
  return summary;
}

async function estimateWithTimeout(
  provider: ServerRoutingProvider,
  request: Readonly<{ purpose: "empty" | "loaded"; waypoints: readonly RoutePoint[] }>,
  timeoutMs: number,
) {
  const controller = new AbortController();
  let timeout: ReturnType<typeof setTimeout>;
  const timeoutFailure = new Promise<never>((_, reject) => {
    timeout = setTimeout(() => {
      controller.abort();
      reject(new Error("routing provider timed out"));
    }, timeoutMs);
  });
  try {
    return await Promise.race([
      provider.estimateRoute(request, { signal: controller.signal }),
      timeoutFailure,
    ]);
  } finally {
    clearTimeout(timeout!);
  }
}

async function releaseClaimSafely(input: ProcessRouteEstimateJobInput): Promise<void> {
  try {
    await input.client.rpc("release_route_estimate_recompute_job", {
      idempotency_key: input.idempotencyKey,
      target_company_id: input.companyId,
      target_job_id: input.jobId,
    });
  } catch {
    // The durable five-minute lease remains a recovery path if transport fails.
  }
}

/**
 * Enqueues the first route estimate. The only caller-owned business value is
 * the dispatcher quote; the database derives driver, planned stops and origin.
 */
export async function requestInitialRouteEstimate(
  input: RequestInitialRouteEstimateInput,
): Promise<MutationResult<RouteEstimateJob>> {
  if (!uuidPattern.test(input.idempotencyKey) || !uuidPattern.test(input.loadId)) {
    return validationError("A valid idempotency key and load are required.", "routing");
  }
  if (!isPositiveDecimal(input.quoteUsd, moneyPattern)) {
    return validationError("A valid decimal quoted USD amount is required.", "routing");
  }
  const response = await input.client.rpc("request_initial_route_estimate", {
    idempotency_key: input.idempotencyKey,
    quoted_amount_usd: input.quoteUsd,
    target_company_id: input.companyId,
    target_load_id: input.loadId,
  });
  if (response.error?.code === "42501") {
    return forbidden();
  }
  if (response.error) {
    return validationError("The initial route estimate could not be requested safely.", "routing");
  }
  const job = parseRouteEstimateJob(response.data);
  return job && job.loadId === input.loadId
    ? ok(job)
    : validationError("The initial route estimate could not be requested safely.", "routing");
}

/**
 * Processes a durable route-recompute job. The database claims the job and
 * returns the session-authorized, bounded load context; callers cannot supply
 * stops, GPS, driver IDs, mileage or route JSON to this boundary.
 */
export async function processRouteEstimateJob(
  input: ProcessRouteEstimateJobInput,
): Promise<MutationResult<RouteEstimateRevision>> {
  if (!uuidPattern.test(input.idempotencyKey) || !uuidPattern.test(input.jobId)) {
    return validationError("A valid idempotency key and route job are required.", "routing");
  }
  const claim = await input.client.rpc("claim_route_estimate_recompute_job", {
    idempotency_key: input.idempotencyKey,
    target_company_id: input.companyId,
    target_job_id: input.jobId,
  });
  if (claim.error?.code === "42501") {
    return forbidden();
  }
  if (claim.error) {
    return validationError("The route job could not be claimed.", "routing");
  }
  const completedRevision = parseCompletedJob(claim.data);
  if (completedRevision) {
    return completedRevision.companyId === input.companyId
      ? ok(completedRevision)
      : validationError("The route job context is invalid or stale.", "routing");
  }
  const context = parseClaimedJob(claim.data);
  if (!context || context.company_id !== input.companyId || context.id !== input.jobId) {
    return validationError("The route job context is invalid or stale.", "routing");
  }

  const timeoutMs = input.timeoutMs ?? defaultProviderTimeoutMs;
  if (!Number.isInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 30_000) {
    return validationError("A valid routing timeout is required.", "routing");
  }

  let emptyLeg;
  let loadedLeg;
  try {
    emptyLeg = await estimateWithTimeout(input.routingProvider, {
      purpose: "empty",
      waypoints: [context.empty_origin, context.planned_stops[0]!],
    }, timeoutMs);
    loadedLeg = await estimateWithTimeout(input.routingProvider, {
      purpose: "loaded",
      waypoints: context.planned_stops,
    }, timeoutMs);
  } catch {
    await releaseClaimSafely(input);
    return validationError("The routing provider could not calculate this estimate.", "routing");
  }

  if (!isNonNegativeMiles(emptyLeg.miles) || !isPositiveDecimal(loadedLeg.miles, milesPattern)) {
    await releaseClaimSafely(input);
    return validationError("The routing provider returned invalid distance values.", "routing");
  }
  const emptySummary = sanitizeRouteSummary(emptyLeg.routeData);
  const loadedSummary = sanitizeRouteSummary(loadedLeg.routeData);
  if (!emptySummary || !loadedSummary) {
    await releaseClaimSafely(input);
    return validationError("The routing provider returned an unsafe route summary.", "routing");
  }

  const complete = await input.client.rpc("complete_route_estimate_recompute_job", {
    calculated_empty_miles: emptyLeg.miles,
    calculated_loaded_miles: loadedLeg.miles,
    context_fingerprint: context.context_fingerprint,
    expected_context_version: context.context_version,
    idempotency_key: input.idempotencyKey,
    provider_name: input.routingProvider.name,
    provider_route_summary: { empty: emptySummary, loaded: loadedSummary },
    target_company_id: input.companyId,
    target_job_id: input.jobId,
  });
  if (complete.error?.code === "42501") {
    return forbidden();
  }
  if (complete.error) {
    await releaseClaimSafely(input);
    return validationError("The route job could not be completed safely.", "routing");
  }
  const completionRevision = parseCompletedJob(complete.data);
  if (completionRevision) {
    return ok(completionRevision);
  }
  if (isRecord(complete.data) && complete.data.status === "stale") {
    return validationError("The route job became stale before the estimate could be published.", "routing");
  }
  await releaseClaimSafely(input);
  return validationError("The route job could not be completed safely.", "routing");
}
