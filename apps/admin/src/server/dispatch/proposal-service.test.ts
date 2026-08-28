import { describe, expect, test } from "vitest";

import { submitAuthorizedLoadProposal } from "./proposal-service";

describe("authorized load proposal boundary", () => {
  test("creates a draft with the caller's durable intent and never requests routing before assignment", async () => {
    const calls: Array<Readonly<{ name: string; args: Record<string, unknown> }>> = [];
    const result = await submitAuthorizedLoadProposal({
      client: { async rpc(name: string, args: Record<string, unknown>) { calls.push({ name, args }); return { data: { id: "11111111-1111-4111-8111-111111111111" }, error: null }; } } as never,
      companyId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", intentKey: "22222222-2222-4222-8222-222222222222", proposal: { delivery: "Delivery", loadNumber: "LOAD-1", pickup: "Pickup", quoteUsd: "250.00" },
    });
    expect(result).toEqual({ ok: true, data: { loadId: "11111111-1111-4111-8111-111111111111", revision: null, routeStatus: "assignment_required" } });
    expect(calls).toEqual([{ name: "create_load_proposal", args: { target_company_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", proposal_intent_key: "22222222-2222-4222-8222-222222222222", proposal_load_number: "LOAD-1", pickup_stop: { address: "Pickup", country: "US", timezone: "America/Chicago" }, delivery_stop: { address: "Delivery", country: "US", timezone: "America/Chicago" }, proposal_quote_usd: "250.00" } }]);
    expect(JSON.stringify(calls)).not.toMatch(/gps|mile|actorRole|driverId|request_initial/i);
  });
});
