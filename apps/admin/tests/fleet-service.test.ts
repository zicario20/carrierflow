import { describe, expect, test } from "vitest";

import {
  assignDriverVehicle,
  createDriver,
  createVehicle,
  endOwnDriverShift,
  startOwnDriverShift,
} from "../src/server/fleet/fleet-service";

const companyId = "11111111-1111-1111-1111-111111111111";
const driverId = "22222222-2222-2222-2222-222222222222";
const vehicleId = "33333333-3333-3333-3333-333333333333";
const membershipId = "44444444-4444-4444-4444-444444444444";

describe("fleet service", () => {
  test("uses the tenant-scoped driver RPC for a dispatcher", async () => {
    const calls: Array<Readonly<{ name: string; arguments: unknown }>> = [];

    const result = await createDriver({
      actorRole: "dispatcher",
      client: {
        async rpc(name, arguments_) {
          calls.push({ name, arguments: arguments_ });
          return {
            data: {
              id: driverId,
              company_id: companyId,
              membership_id: membershipId,
              display_name: "Taylor Driver",
              status: "active",
            },
            error: null,
          };
        },
      },
      companyId,
      displayName: "Taylor Driver",
      membershipId,
    });

    expect(calls).toEqual([
      {
        name: "create_driver",
        arguments: {
          target_company_id: companyId,
          target_membership_id: membershipId,
          driver_display_name: "Taylor Driver",
        },
      },
    ]);
    expect(result).toEqual({
      ok: true,
      data: {
        id: driverId,
        companyId,
        membershipId,
        displayName: "Taylor Driver",
        status: "active",
      },
    });
  });

  test("does not invoke a fleet mutation for a driver actor", async () => {
    let rpcWasCalled = false;

    const result = await createVehicle({
      actorRole: "driver",
      client: {
        async rpc() {
          rpcWasCalled = true;
          return { data: null, error: null };
        },
      },
      companyId,
      type: "cargo_van",
      unitNumber: "A-1",
    });

    expect(result).toEqual({
      ok: false,
      error: {
        code: "forbidden",
        message: "You do not have permission to perform this action.",
      },
    });
    expect(rpcWasCalled).toBe(false);
  });

  test("maps inactive assignment database validation to a typed validation result", async () => {
    const result = await assignDriverVehicle({
      actorRole: "dispatcher",
      client: {
        async rpc() {
          return { data: null, error: { code: "22023" } };
        },
      },
      companyId,
      driverId,
      vehicleId,
    });

    expect(result).toEqual({
      ok: false,
      error: {
        code: "validation",
        field: "assignment",
        message: "The driver and vehicle must be active before assignment.",
      },
    });
  });

  test("uses the own-shift RPCs only for a driver", async () => {
    const calls: string[] = [];
    const client = {
      async rpc(name: string) {
        calls.push(name);
        return {
          data: {
            id: "55555555-5555-5555-5555-555555555555",
            company_id: companyId,
            driver_id: driverId,
            on_duty_at: "2026-08-27T12:00:00.000Z",
            off_duty_at: null,
          },
          error: null,
        };
      },
    };

    await startOwnDriverShift({ actorRole: "driver", client, driverId });
    await endOwnDriverShift({ actorRole: "driver", client, driverId });

    expect(calls).toEqual(["start_driver_shift", "end_driver_shift"]);
  });
});
