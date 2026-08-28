import { describe, expect, test } from "vitest";

import { assignLoadResources, cancelLoadIdempotently } from "./assignment-service";

describe("safe assignment boundary", () => {
  test("uses the caller intent then exposes truthful pending routing with no provider", async () => {
    const calls: unknown[] = [];
    const result = await assignLoadResources({
      client: { async rpc(name, args) { calls.push({ name, args }); return name === "assign_load_resources" ? { data: { company_id: "company", id: "load", operational_status: "assigned" }, error: null } : { data: { status: "pending", jobId: "job", idempotencyKey: "33333333-3333-4333-8333-333333333333" }, error: null }; } },
      companyId: "company", driverId: "driver", idempotencyKey: "11111111-1111-4111-8111-111111111111", loadId: "load", routingProvider: null, vehicleId: "vehicle",
    });
    expect(result).toEqual({ ok: true, data: { load: { companyId: "company", id: "load", operationalStatus: "assigned" }, revision: null, routeStatus: "pending" } });
    expect(calls).toEqual([
      { name: "assign_load_resources", args: { idempotency_key: "11111111-1111-4111-8111-111111111111", target_company_id: "company", target_driver_id: "driver", target_load_id: "load", target_vehicle_id: "vehicle" } },
      { name: "get_dispatch_route_estimate_status", args: { target_company_id: "company", target_load_id: "load" } },
    ]);
  });

  test("returns the immutable ready revision when the same assignment intent is retried after routing completes", async () => {
    let routeStatusReads = 0;
    const calls: unknown[] = [];
    const client = {
      async rpc(name: string, args: Record<string, unknown>) {
        calls.push({ name, args });
        if (name === "assign_load_resources") return { data: { company_id: "company", id: "load", operational_status: "assigned" }, error: null };
        routeStatusReads += 1;
        return routeStatusReads === 1
          ? { data: { status: "pending", jobId: "22222222-2222-4222-8222-222222222222", idempotencyKey: "33333333-3333-4333-8333-333333333333" }, error: null }
          : { data: { status: "ready", revision: { company_id: "company", empty_miles: "12.500", id: "44444444-4444-4444-8444-444444444444", loaded_miles: "87.500", quote_usd: "250.00", quote_usd_per_total_mile: "2.5000000000000000", revision_number: 2, total_miles: "100.000" } }, error: null };
      },
    };
    const request = { client, companyId: "company", driverId: "driver", idempotencyKey: "11111111-1111-4111-8111-111111111111", loadId: "load", routingProvider: null, vehicleId: "vehicle" } as const;
    await expect(assignLoadResources(request)).resolves.toEqual({ ok: true, data: { load: { companyId: "company", id: "load", operationalStatus: "assigned" }, revision: null, routeStatus: "pending" } });
    await expect(assignLoadResources(request)).resolves.toEqual({ ok: true, data: { load: { companyId: "company", id: "load", operationalStatus: "assigned" }, revision: { companyId: "company", emptyMiles: "12.500", id: "44444444-4444-4444-8444-444444444444", loadedMiles: "87.500", quoteUsd: "250.00", quoteUsdPerTotalMile: "2.5000000000000000", revisionNumber: 2, totalMiles: "100.000" }, routeStatus: "ready" } });
    expect(calls.filter((call) => (call as { name: string }).name === "assign_load_resources")).toEqual([
      { name: "assign_load_resources", args: { idempotency_key: "11111111-1111-4111-8111-111111111111", target_company_id: "company", target_driver_id: "driver", target_load_id: "load", target_vehicle_id: "vehicle" } },
      { name: "assign_load_resources", args: { idempotency_key: "11111111-1111-4111-8111-111111111111", target_company_id: "company", target_driver_id: "driver", target_load_id: "load", target_vehicle_id: "vehicle" } },
    ]);
  });

  test("rejects a malformed ready route-status receipt instead of inventing a pending result", async () => {
    const result = await assignLoadResources({
      client: { async rpc(name: string) { return name === "assign_load_resources" ? { data: { company_id: "company", id: "load", operational_status: "assigned" }, error: null } : { data: { status: "ready", revision: { company_id: "company", empty_miles: "12.500" } }, error: null }; } },
      companyId: "company", driverId: "driver", idempotencyKey: "11111111-1111-4111-8111-111111111111", loadId: "load", routingProvider: null, vehicleId: "vehicle",
    });
    expect(result).toEqual({ ok: false, error: { code: "validation", field: "routing", message: "The route estimate status was invalid." } });
  });

  test("processes the server-provided job with an optional provider into a ready immutable revision", async () => {
    const provider = { name: "test", async estimateRoute(request: { purpose: "empty" | "loaded" }) { return request.purpose === "empty" ? { miles: "10.000", routeData: { distanceMeters: 16093 } } : { miles: "90.000", routeData: { distanceMeters: 144841 } }; } };
    const result = await assignLoadResources({
      client: { async rpc(name: string) {
        if (name === "assign_load_resources") return { data: { company_id: "company", id: "load", operational_status: "assigned" }, error: null };
        if (name === "get_dispatch_route_estimate_status") return { data: { status: "pending", jobId: "22222222-2222-4222-8222-222222222222", idempotencyKey: "33333333-3333-4333-8333-333333333333" }, error: null };
        if (name === "claim_route_estimate_recompute_job") return { data: { id: "22222222-2222-4222-8222-222222222222", company_id: "company", load_id: "load", context_version: 1, context_fingerprint: "a".repeat(16), quote_usd: "250.00", empty_origin_kind: "declared_base", empty_origin: { id: "base", label: "Base", latitude: 1, longitude: 1 }, planned_stops: [{ id: "pickup", label: "Pickup", latitude: 2, longitude: 2 }, { id: "delivery", label: "Delivery", latitude: 3, longitude: 3 }] }, error: null };
        if (name === "complete_route_estimate_recompute_job") return { data: { status: "completed", revision: { id: "revision", company_id: "company", revision_number: 1, empty_miles: "10.000", loaded_miles: "90.000", total_miles: "100.000", quote_usd: "250.00", quote_usd_per_total_mile: "2.5000000000000000" } }, error: null };
        return { data: null, error: null };
      } } as never,
      companyId: "company", driverId: "driver", idempotencyKey: "11111111-1111-4111-8111-111111111111", loadId: "load", routingProvider: provider, vehicleId: "vehicle",
    });
    expect(result).toMatchObject({ ok: true, data: { routeStatus: "ready", revision: { emptyMiles: "10.000", loadedMiles: "90.000", totalMiles: "100.000" } } });
  });

  test("cancels with a caller-owned intent rather than a server-generated retry key", async () => {
    const calls: unknown[] = [];
    const result = await cancelLoadIdempotently({ client: { async rpc(name, args) { calls.push({ name, args }); return { data: { company_id: "company", id: "load", operational_status: "cancelled" }, error: null }; } }, companyId: "company", idempotencyKey: "44444444-4444-4444-8444-444444444444", loadId: "load" });
    expect(result).toMatchObject({ ok: true, data: { operationalStatus: "cancelled" } });
    expect(calls).toEqual([{ name: "cancel_load_idempotent", args: { idempotency_key: "44444444-4444-4444-8444-444444444444", target_company_id: "company", target_load_id: "load" } }]);
  });
});
