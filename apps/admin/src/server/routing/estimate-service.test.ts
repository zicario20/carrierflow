import { describe, expect, test } from "vitest";

const companyId = "11111111-1111-1111-1111-111111111111";
const loadId = "22222222-2222-4222-8222-222222222222";
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

describe("route estimate service", () => {
  test("queues an initial quote without accepting driver, stops, GPS, miles or provider data", async () => {
    const { requestInitialRouteEstimate } = await import("./estimate-service");
    const calls: Array<Readonly<{ name: string; arguments: unknown }>> = [];

    const result = await requestInitialRouteEstimate({
      client: {
        async rpc(name: string, arguments_: unknown) {
          calls.push({ name, arguments: arguments_ });
          return {
            data: {
              context_fingerprint: "context-fingerprint-v2",
              id: jobId,
              idempotency_key: idempotencyKey,
              load_id: loadId,
              quote_usd: "250.00",
            },
            error: null,
          };
        },
      },
      companyId,
      idempotencyKey,
      loadId,
      quoteUsd: "250.00",
      ...( { driverId: "attacker", plannedStops: [point("attacker", "Attacker")], liveGps: point("gps", "GPS"), miles: "1" } as object),
    });

    expect(calls).toEqual([{
      name: "request_initial_route_estimate",
      arguments: {
        idempotency_key: idempotencyKey,
        quoted_amount_usd: "250.00",
        target_company_id: companyId,
        target_load_id: loadId,
      },
    }]);
    expect(result).toMatchObject({ ok: true, data: { id: jobId, contextFingerprint: "context-fingerprint-v2" } });
  });

  test("persists dispatcher pricing as separate exact decimal values through the job boundary", async () => {
    const { processRouteEstimateJob } = await import("./estimate-service");
    const calls: Array<Readonly<{ name: string; arguments: Record<string, unknown> }>> = [];
    let estimateCount = 0;

    const result = await processRouteEstimateJob({
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
          estimateCount += 1;
          return estimateCount === 1
            ? { miles: "12.500", routeData: { distanceMeters: 20116, durationSeconds: 1200 } }
            : { miles: "87.500", routeData: { distanceMeters: 140817, durationSeconds: 7200 } };
        },
      },
    });

    expect(calls[1]).toEqual({
      name: "complete_route_estimate_recompute_job",
      arguments: {
        calculated_empty_miles: "12.500",
        calculated_loaded_miles: "87.500",
        context_fingerprint: "context-fingerprint-v2",
        expected_context_version: 2,
        idempotency_key: idempotencyKey,
        provider_name: "test-routing",
        provider_route_summary: {
          empty: { distanceMeters: 20116, durationSeconds: 1200 },
          loaded: { distanceMeters: 140817, durationSeconds: 7200 },
        },
        target_company_id: companyId,
        target_job_id: jobId,
      },
    });
    expect(result).toEqual({
      ok: true,
      data: {
        companyId,
        emptyMiles: "12.500",
        id: "55555555-5555-5555-5555-555555555555",
        loadedMiles: "87.500",
        quoteUsd: "250.00",
        quoteUsdPerTotalMile: "2.5000000000000000",
        revisionNumber: 2,
        totalMiles: "100.000",
      },
    });
  });

  test("rejects a denied job before a server-owned provider call", async () => {
    const { processRouteEstimateJob } = await import("./estimate-service");
    let providerWasCalled = false;

    const result = await processRouteEstimateJob({
      client: {
        async rpc() {
          return { data: null, error: { code: "42501" } };
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

    expect(result).toEqual({
      ok: false,
      error: {
        code: "forbidden",
        message: "You do not have permission to perform this action.",
      },
    });
    expect(providerWasCalled).toBe(false);
  });

  test("does not publish an obsolete provider result when completion returns typed stale state", async () => {
    const { processRouteEstimateJob } = await import("./estimate-service");

    const result = await processRouteEstimateJob({
      client: {
        async rpc(name: string) {
          if (name === "claim_route_estimate_recompute_job") {
            return { data: claimedContext, error: null };
          }
          return { data: { status: "stale", reason: "context_changed" }, error: null };
        },
      },
      companyId,
      idempotencyKey,
      jobId,
      routingProvider: {
        name: "test-routing",
        async estimateRoute() {
          return { miles: "12.500", routeData: { distanceMeters: 20116, durationSeconds: 1200 } };
        },
      },
    });

    expect(result).toEqual({
      ok: false,
      error: {
        code: "validation",
        field: "routing",
        message: "The route job became stale before the estimate could be published.",
      },
    });
  });
});
