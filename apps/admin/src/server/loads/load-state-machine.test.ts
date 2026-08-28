import { describe, expect, test } from "vitest";

import {
  advanceLoadState,
  formatLoadIncidentType,
  formatLoadOperationalStatus,
  missingRequiredDeliveryEvidence,
  reportLoadIncident,
  type TrustedLoadSupabaseClient,
} from "./load-service";

const companyId = "11111111-1111-1111-1111-111111111111";
const loadId = "22222222-2222-2222-2222-222222222222";

describe("load state machine", () => {
  test("does not attempt delivery before pickup and keeps the current state", async () => {
    let rpcWasCalled = false;

    const result = await advanceLoadState({
      actorRole: "driver",
      client: {
        async rpc() {
          rpcWasCalled = true;
          return { data: null, error: null };
        },
      },
      companyId,
      currentStatus: "assigned",
      loadId,
      nextStatus: "delivered",
    });

    expect(result).toEqual({
      ok: false,
      error: {
        code: "validation",
        field: "status",
        message: "A load must be picked up before it can be delivered.",
      },
    });
    expect(rpcWasCalled).toBe(false);
  });

  test("uses the tenant-scoped state RPC for an allowed ordered transition", async () => {
    const calls: Array<Readonly<{ name: string; arguments: unknown }>> = [];

    const result = await advanceLoadState({
      actorRole: "driver",
      client: {
        async rpc(name, arguments_) {
          calls.push({ name, arguments: arguments_ });
          return {
            data: {
              company_id: companyId,
              id: loadId,
              operational_status: "en_route_to_pickup",
            },
            error: null,
          };
        },
      },
      companyId,
      currentStatus: "assigned",
      loadId,
      nextStatus: "en_route_to_pickup",
    });

    expect(calls).toEqual([
      {
        name: "advance_load_state",
        arguments: {
          target_company_id: companyId,
          target_load_id: loadId,
          target_operational_status: "en_route_to_pickup",
        },
      },
    ]);
    expect(result).toEqual({
      ok: true,
      data: {
        companyId,
        id: loadId,
        operationalStatus: "en_route_to_pickup",
      },
    });
  });

  test("allows only a manager to request the audited cancellation RPC", async () => {
    const calls: unknown[] = [];
    const result = await advanceLoadState({
      actorRole: "dispatcher", client: { async rpc(name, arguments_) { calls.push({ name, arguments: arguments_ }); return { data: { company_id: companyId, id: loadId, operational_status: "cancelled" }, error: null }; } },
      companyId, currentStatus: "assigned", loadId, nextStatus: "cancelled",
    });
    expect(result).toEqual({ ok: true, data: { companyId, id: loadId, operationalStatus: "cancelled" } });
    expect(calls).toHaveLength(1);
  });

  test("identifies every missing required non-photo delivery evidence item", () => {
    expect(
      missingRequiredDeliveryEvidence({
        requirements: ["photo", "signature", "bol", "receiver_name"],
        submittedEvidence: ["receiver_name"],
      }),
    ).toEqual(["signature", "bol"]);
  });

  test("reports a typed incident without requesting a load state mutation", async () => {
    const calls: Array<Readonly<{ name: string; arguments: unknown }>> = [];
    const client: TrustedLoadSupabaseClient = {
      async rpc(name, arguments_) {
        calls.push({ name, arguments: arguments_ });
        return {
          data: {
            company_id: companyId,
            id: "33333333-3333-3333-3333-333333333333",
            load_id: loadId,
            status: "open",
          },
          error: null,
        };
      },
    };

    const result = await reportLoadIncident({
      actorRole: "driver",
      attachments: ["private/evidence/incident-1.pdf"],
      client,
      companyId,
      description: "Receiver asked the driver to wait at the gate.",
      incidentType: "customer_unavailable",
      loadId,
      location: { latitude: 41.8781, longitude: -87.6298 },
    });

    expect(calls).toEqual([
      {
        name: "report_load_incident",
        arguments: {
          incident_attachments: ["private/evidence/incident-1.pdf"],
          incident_description: "Receiver asked the driver to wait at the gate.",
          incident_location: { latitude: 41.8781, longitude: -87.6298 },
          incident_type_value: "customer_unavailable",
          target_company_id: companyId,
          target_load_id: loadId,
        },
      },
    ]);
    expect(result).toEqual({
      ok: true,
      data: {
        companyId,
        id: "33333333-3333-3333-3333-333333333333",
        loadId,
        status: "open",
      },
    });
  });

  test("localizes operational state and incident values without exposing raw database enums", () => {
    expect(formatLoadOperationalStatus("en_route_to_delivery", "en")).toBe("En route to delivery");
    expect(formatLoadOperationalStatus("en_route_to_delivery", "es")).toBe("En camino a la entrega");
    expect(formatLoadIncidentType("customer_unavailable", "en")).toBe("Customer unavailable");
    expect(formatLoadIncidentType("customer_unavailable", "es")).toBe("Cliente no disponible");
  });
});
