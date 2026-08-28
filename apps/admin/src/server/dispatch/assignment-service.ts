import "server-only";

import { forbidden, ok, validationError, type MutationResult } from "../result";
import type { LoadOperationalStatus, LoadState } from "../loads/load-service";
import { parseRouteEstimateRevision, processRouteEstimateJob, type RouteEstimateRevision, type TrustedRouteEstimateClient } from "../routing/estimate-service";
import type { ServerRoutingProvider } from "../routing/routing-provider";

type AssignmentClient = Readonly<{
  rpc: (name: string, args: Record<string, unknown>) => Promise<Readonly<{ data: unknown | null; error: Readonly<{ code?: string }> | null }>>;
}>;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type AssignmentSubmission = Readonly<{
  load: LoadState;
  revision: RouteEstimateRevision | null;
  routeStatus: "pending" | "ready";
}>;

function parseLoad(value: unknown): LoadState | null {
  if (!value || typeof value !== "object") return null;
  const row = value as { company_id?: unknown; id?: unknown; operational_status?: unknown };
  return typeof row.company_id === "string" && typeof row.id === "string" && typeof row.operational_status === "string"
    ? { companyId: row.company_id, id: row.id, operationalStatus: row.operational_status as LoadOperationalStatus }
    : null;
}

function pendingJob(value: unknown): Readonly<{ id: string; idempotencyKey: string }> | null {
  if (!value || typeof value !== "object") return null;
  const row = value as { status?: unknown; jobId?: unknown; idempotencyKey?: unknown };
  return row.status === "pending" && typeof row.jobId === "string" && typeof row.idempotencyKey === "string"
    ? { id: row.jobId, idempotencyKey: row.idempotencyKey }
    : null;
}

function readyRevision(value: unknown, companyId: string): RouteEstimateRevision | "invalid" | null {
  if (!value || typeof value !== "object" || (value as { status?: unknown }).status !== "ready") return null;
  const revision = parseRouteEstimateRevision((value as { revision?: unknown }).revision);
  return revision && revision.companyId === companyId ? revision : "invalid";
}

/** Calls the DB's manager-only, idempotent assignment RPC. No browser role is trusted. */
export async function assignLoadResources(input: Readonly<{
  client: AssignmentClient;
  companyId: string;
  driverId: string;
  idempotencyKey: string;
  loadId: string;
  routingProvider: ServerRoutingProvider | null;
  vehicleId: string;
}>): Promise<MutationResult<AssignmentSubmission>> {
  if (!input.loadId || !input.driverId || !input.vehicleId || !uuidPattern.test(input.idempotencyKey)) return validationError("Load, driver, vehicle, and a valid retry key are required.", "assignment");
  const response = await input.client.rpc("assign_load_resources", {
    idempotency_key: input.idempotencyKey,
    target_company_id: input.companyId,
    target_driver_id: input.driverId,
    target_load_id: input.loadId,
    target_vehicle_id: input.vehicleId,
  });
  if (response.error?.code === "42501") return forbidden();
  const load = response.error ? null : parseLoad(response.data);
  if (!load || load.companyId !== input.companyId) return validationError("The load assignment was rejected by the server.", "assignment");
  const route = await input.client.rpc("get_dispatch_route_estimate_status", {
    target_company_id: input.companyId,
    target_load_id: input.loadId,
  });
  if (route.error?.code === "42501") return forbidden();
  const ready = route.error ? null : readyRevision(route.data, input.companyId);
  if (ready === "invalid") return validationError("The route estimate status was invalid.", "routing");
  if (ready) return ok({ load, revision: ready, routeStatus: "ready" });
  const job = route.error ? null : pendingJob(route.data);
  if (!job || !input.routingProvider) return ok({ load, revision: null, routeStatus: "pending" });
  const processed = await processRouteEstimateJob({
    client: input.client as TrustedRouteEstimateClient,
    companyId: input.companyId,
    idempotencyKey: job.idempotencyKey,
    jobId: job.id,
    routingProvider: input.routingProvider,
  });
  return processed.ok
    ? ok({ load, revision: processed.data, routeStatus: "ready" })
    : ok({ load, revision: null, routeStatus: "pending" });
}

/** Uses the database state-machine through a durable cancellation receipt. */
export async function cancelLoadIdempotently(input: Readonly<{
  client: AssignmentClient;
  companyId: string;
  idempotencyKey: string;
  loadId: string;
}>): Promise<MutationResult<LoadState>> {
  if (!input.loadId || !uuidPattern.test(input.idempotencyKey)) return validationError("Load and a valid retry key are required.", "cancellation");
  const response = await input.client.rpc("cancel_load_idempotent", {
    idempotency_key: input.idempotencyKey,
    target_company_id: input.companyId,
    target_load_id: input.loadId,
  });
  if (response.error?.code === "42501") return forbidden();
  const load = response.error ? null : parseLoad(response.data);
  return load && load.companyId === input.companyId ? ok(load) : validationError("The load cancellation was rejected by the server.", "cancellation");
}
