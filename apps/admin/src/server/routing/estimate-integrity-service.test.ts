import { describe, expect, test } from "vitest";

const companyId = "11111111-1111-1111-1111-111111111111";
const loadId = "22222222-2222-2222-2222-222222222222";
const jobId = "33333333-3333-4333-8333-333333333333";
const idempotencyKey = "44444444-4444-4444-8444-444444444444";

const point = (id: string, label: string) => ({
  id,
  label,
  latitude: 41.8781,
  longitude: -87.6298,
});

const claimedContext = {
  company_id: companyId,
  context_fingerprint: "context-fingerprint-v2",
  context_version: 2,
  empty_origin: point("active-final", "Active final planned stop"),
  empty_origin_kind: "active_load_final_stop",
  id: jobId,
  load_id: loadId,
  planned_stops: [point("pickup", "Pickup"), point("delivery", "Delivery")],
  quote_usd: "250.00",
};

describe("route estimate integrity service", () => {
  test("derives provider waypoints from the session-authorized claimed context, not caller GPS or stops", async () => {
    const { processRouteEstimateJob } = await import("./estimate-service");
    const calls: Array<Readonly<{ name: string; arguments: unknown }>> = [];
    const providerRequests: unknown[] = [];

    const result = await processRouteEstimateJob({
      client: {
        async rpc(name: string, arguments_: unknown) {
          calls.push({ name, arguments: arguments_ });
          if (name === "claim_route_estimate_recompute_job") {
            return { data: claimedContext, error: null };
          }
          return {
            data: {
              status: "completed",
              revision: {
                company_id: companyId,
                empty_miles: "12.500",
                id: "55555555-5555-5555-5555-555555555555",
                loaded_miles: "87.500",
                quote_usd: "250.00",
                quote_usd_per_total_mile: "2.5000000000000000",
                revision_number: 2,
                total_miles: "100.000",
              },
            },
            error: null,
          };
        },
      },
      companyId,
      idempotencyKey,
      jobId,
      routingProvider: {
        name: "test-routing",
        async estimateRoute(request: unknown) {
          providerRequests.push(request);
          return { miles: providerRequests.length === 1 ? "12.500" : "87.500", routeData: {} };
        },
      },
      // Runtime junk must never alter the server-derived route context.
      ...( { plannedStops: [point("attacker", "Attacker stop")], liveGps: point("gps", "GPS") } as object),
    });

    expect(providerRequests[0]).toEqual({
      purpose: "empty",
      waypoints: [claimedContext.empty_origin, claimedContext.planned_stops[0]],
    });
    expect(providerRequests[1]).toEqual({
      purpose: "loaded",
      waypoints: claimedContext.planned_stops,
    });
    expect(calls[0]).toEqual({
      name: "claim_route_estimate_recompute_job",
      arguments: {
        idempotency_key: idempotencyKey,
        target_company_id: companyId,
        target_job_id: jobId,
      },
    });
    expect(result).toMatchObject({ ok: true, data: { revisionNumber: 2 } });
  });

  test("persists only the bounded route-summary allowlist and never provider secrets or geometry", async () => {
    const { processRouteEstimateJob } = await import("./estimate-service");
    const calls: Array<Readonly<{ name: string; arguments: Record<string, unknown> }>> = [];

    await processRouteEstimateJob({
      client: {
        async rpc(name: string, arguments_: Record<string, unknown>) {
          calls.push({ name, arguments: arguments_ });
          if (name === "claim_route_estimate_recompute_job") {
            return { data: claimedContext, error: null };
          }
          return {
            data: {
              status: "completed",
              revision: {
                company_id: companyId,
                empty_miles: "12.500",
                id: "55555555-5555-5555-5555-555555555555",
                loaded_miles: "87.500",
                quote_usd: "250.00",
                quote_usd_per_total_mile: "2.5000000000000000",
                revision_number: 2,
                total_miles: "100.000",
              },
            },
            error: null,
          };
        },
      },
      companyId,
      idempotencyKey,
      jobId,
      routingProvider: {
        name: "test-routing",
        async estimateRoute() {
          return {
            miles: "12.500",
            routeData: {
              apiKey: "must-not-persist",
              authorization: "Bearer must-not-persist",
              distanceMeters: 20116,
              durationSeconds: 1800,
              geometry: "must-not-persist",
            },
          };
        },
      },
    });

    expect(calls[1]).toMatchObject({
      name: "complete_route_estimate_recompute_job",
      arguments: {
        provider_route_summary: {
          empty: { distanceMeters: 20116, durationSeconds: 1800 },
          loaded: { distanceMeters: 20116, durationSeconds: 1800 },
        },
      },
    });
    expect(JSON.stringify(calls[1])).not.toContain("must-not-persist");
  });

  test("rejects an oversized provider summary before completion", async () => {
    const { processRouteEstimateJob } = await import("./estimate-service");
    let completionWasCalled = false;

    const result = await processRouteEstimateJob({
      client: {
        async rpc(name: string) {
          if (name === "claim_route_estimate_recompute_job") {
            return { data: claimedContext, error: null };
          }
          completionWasCalled ||= name === "complete_route_estimate_recompute_job";
          return { data: null, error: null };
        },
      },
      companyId,
      idempotencyKey,
      jobId,
      routingProvider: {
        name: "test-routing",
        async estimateRoute() {
          return { miles: "12.500", routeData: { distanceMeters: 1, note: "x".repeat(9_000) } };
        },
      },
    });

    expect(result).toEqual({
      ok: false,
      error: {
        code: "validation",
        field: "routing",
        message: "The routing provider returned an unsafe route summary.",
      },
    });
    expect(completionWasCalled).toBe(false);
  });

  test("measures provider summaries in UTF-8 bytes before persistence", async () => {
    const { processRouteEstimateJob } = await import("./estimate-service");
    let completionWasCalled = false;

    const result = await processRouteEstimateJob({
      client: {
        async rpc(name: string) {
          if (name === "claim_route_estimate_recompute_job") {
            return { data: claimedContext, error: null };
          }
          completionWasCalled ||= name === "complete_route_estimate_recompute_job";
          return { data: null, error: null };
        },
      },
      companyId,
      idempotencyKey,
      jobId,
      routingProvider: {
        name: "test-routing",
        async estimateRoute() {
          return { miles: "12.500", routeData: { distanceMeters: 1, note: "🚚".repeat(3_000) } };
        },
      },
    });

    expect(result).toMatchObject({ ok: false, error: { code: "validation", field: "routing" } });
    expect(completionWasCalled).toBe(false);
  });

  test("returns a completed revision on an idempotent retry without calling the provider again", async () => {
    const { processRouteEstimateJob } = await import("./estimate-service");
    let providerWasCalled = false;

    const result = await processRouteEstimateJob({
      client: {
        async rpc() {
          return {
            data: {
              status: "completed",
              revision: {
                company_id: companyId,
                empty_miles: "12.500",
                id: "55555555-5555-5555-5555-555555555555",
                loaded_miles: "87.500",
                quote_usd: "250.00",
                quote_usd_per_total_mile: "2.5000000000000000",
                revision_number: 2,
                total_miles: "100.000",
              },
            },
            error: null,
          };
        },
      },
      companyId,
      idempotencyKey,
      jobId,
      routingProvider: {
        name: "test-routing",
        async estimateRoute() {
          providerWasCalled = true;
          return { miles: "1.000", routeData: {} };
        },
      },
    });

    expect(result).toMatchObject({ ok: true, data: { revisionNumber: 2 } });
    expect(providerWasCalled).toBe(false);
  });

  test("fails closed when a routing adapter ignores cancellation", async () => {
    const { processRouteEstimateJob } = await import("./estimate-service");
    const calls: string[] = [];
    const result = await Promise.race([
      processRouteEstimateJob({
        client: {
          async rpc(name: string) {
            calls.push(name);
            if (name === "claim_route_estimate_recompute_job") {
              return { data: claimedContext, error: null };
            }
            return { data: null, error: null };
          },
        },
        companyId,
        idempotencyKey,
        jobId,
        timeoutMs: 100,
        routingProvider: {
          name: "test-routing",
          async estimateRoute() {
            return new Promise(() => undefined);
          },
        },
      }),
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error("routing timeout was not enforced")), 250)),
    ]);

    expect(result).toMatchObject({ ok: false, error: { code: "validation", field: "routing" } });
    expect(calls).toContain("release_route_estimate_recompute_job");
  });
});
