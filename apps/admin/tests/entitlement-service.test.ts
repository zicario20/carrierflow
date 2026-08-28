import { describe, expect, test } from "vitest";

import {
  getPilotEntitlement,
} from "../src/server/billing/entitlement-service";
import {
  runPilotPrivacyRetention,
} from "../src/server/privacy/retention-service";

const companyId = "11111111-1111-1111-1111-111111111111";

const entitlementPayload = {
  activeDriverCount: 4,
  availableDriverSlots: 6,
  driverCapacity: 10,
  monthlyPriceUsd: 20,
  planCode: "starter",
  trialEndsAt: "2026-09-04T12:00:00.000Z",
  trialStartedAt: "2026-08-28T12:00:00.000Z",
  trialState: "active",
};

describe("pilot entitlement and privacy services", () => {
  test("uses only the owner-authorized entitlement RPC and parses the fixed pilot catalogue", async () => {
    const calls: Array<Readonly<{ arguments: unknown; name: string }>> = [];

    await expect(getPilotEntitlement({
      actorRole: "owner",
      client: {
        async rpc(name, arguments_) {
          calls.push({ arguments: arguments_, name });
          return { data: entitlementPayload, error: null };
        },
      },
      companyId,
    })).resolves.toEqual({
      ok: true,
      data: {
        activeDriverCount: 4,
        availableDriverSlots: 6,
        driverCapacity: 10,
        monthlyPriceUsd: 20,
        planCode: "starter",
        trialEndsAt: "2026-09-04T12:00:00.000Z",
        trialStartedAt: "2026-08-28T12:00:00.000Z",
        trialState: "active",
      },
    });
    expect(calls).toEqual([
      {
        arguments: { target_company_id: companyId },
        name: "get_company_pilot_entitlement",
      },
    ]);
  });

  test("fails closed without querying for non-owner or malformed plan data", async () => {
    let rpcCalls = 0;
    const nonOwner = await getPilotEntitlement({
      actorRole: "dispatcher",
      client: {
        async rpc() {
          rpcCalls += 1;
          return { data: entitlementPayload, error: null };
        },
      },
      companyId,
    });
    const malformed = await getPilotEntitlement({
      actorRole: "owner",
      client: {
        async rpc() {
          return { data: { ...entitlementPayload, driverCapacity: 60, monthlyPriceUsd: 20 }, error: null };
        },
      },
      companyId,
    });

    expect(nonOwner).toMatchObject({ ok: false, error: { code: "forbidden" } });
    expect(rpcCalls).toBe(0);
    expect(malformed).toMatchObject({ ok: false, error: { code: "validation" } });
  });

  test("preserves an actual database authorization denial so the page can distinguish it from an outage", async () => {
    await expect(getPilotEntitlement({
      actorRole: "owner",
      client: {
        async rpc() {
          return { data: null, error: { code: "42501" } };
        },
      },
      companyId,
    })).resolves.toEqual({
      ok: false,
      error: {
        code: "forbidden",
        message: "You do not have permission to perform this action.",
      },
    });
  });

  test("runs retention only through the owner-authorized RPC and strips all sensitive fields", async () => {
    const calls: Array<Readonly<{ arguments: unknown; name: string }>> = [];

    await expect(runPilotPrivacyRetention({
      actorRole: "owner",
      client: {
        async rpc(name, arguments_) {
          calls.push({ arguments: arguments_, name });
          return {
            data: {
              policyVersion: "pilot-v1",
              preservedEvidenceMetadataCount: 12,
              purgedCurrentLocationCount: 2,
              purgedDetailedLocationCount: 8,
              latitude: 41.8781,
              token: "must-not-leave-the-rpc-boundary",
            },
            error: null,
          };
        },
      },
      companyId,
    })).resolves.toEqual({
      ok: true,
      data: {
        policyVersion: "pilot-v1",
        preservedEvidenceMetadataCount: 12,
        purgedCurrentLocationCount: 2,
        purgedDetailedLocationCount: 8,
      },
    });
    expect(calls).toEqual([
      {
        arguments: { target_company_id: companyId },
        name: "run_pilot_privacy_retention",
      },
    ]);
  });

  test("does not invoke privacy retention for a non-owner", async () => {
    let rpcWasCalled = false;

    await expect(runPilotPrivacyRetention({
      actorRole: "admin",
      client: {
        async rpc() {
          rpcWasCalled = true;
          return { data: null, error: null };
        },
      },
      companyId,
    })).resolves.toMatchObject({ ok: false, error: { code: "forbidden" } });
    expect(rpcWasCalled).toBe(false);
  });
});
