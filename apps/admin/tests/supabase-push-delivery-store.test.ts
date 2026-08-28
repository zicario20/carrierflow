import { describe, expect, test } from "vitest";

import {
  SupabaseDriverPushDeliveryStore,
  type ServerOnlyPushRpcClient,
} from "../src/server/notifications/supabase-push-delivery-store";

const workerId = "11111111-1111-4111-8111-111111111111";
const deliveryId = "22222222-2222-4222-8222-222222222222";
const leaseToken = "33333333-3333-4333-8333-333333333333";
const notificationId = "44444444-4444-4444-8444-444444444444";

class FakeServiceRoleRpcClient implements ServerOnlyPushRpcClient {
  responses = new Map<string, unknown>();
  calls: Array<{ name: string; arguments: Record<string, unknown> }> = [];

  async rpc(name: string, params: Record<string, unknown>) {
    this.calls.push({ name, arguments: params });
    return { data: this.responses.get(name) ?? null, error: null };
  }
}

describe("Supabase service-role push delivery store", () => {
  test("maps only a private worker claim and invokes lease RPCs without scope arguments", async () => {
    const client = new FakeServiceRoleRpcClient();
    client.responses.set("claim_pending_driver_push_delivery", {
      deliveryId,
      ciphertext: Buffer.from("ciphertext-not-a-provider-token").toString("base64"),
      iv: Buffer.alloc(12, 1).toString("base64"),
      authTag: Buffer.alloc(16, 2).toString("base64"),
      leaseToken,
      notificationId,
      companyId: "must-not-cross-the-worker-boundary",
    });
    const store = new SupabaseDriverPushDeliveryStore(client);

    await expect(store.claimNext(workerId)).resolves.toEqual({
      deliveryId,
      encryptedToken: {
        ciphertext: Buffer.from("ciphertext-not-a-provider-token"),
        iv: Buffer.alloc(12, 1),
        authTag: Buffer.alloc(16, 2),
      },
      leaseToken,
      notificationId,
    });
    await store.complete(deliveryId, leaseToken);
    await store.invalidateDevice(deliveryId, leaseToken);
    await store.release(deliveryId, leaseToken);

    expect(client.calls).toEqual([
      {
        name: "claim_pending_driver_push_delivery",
        arguments: { worker_id: workerId },
      },
      {
        name: "complete_driver_push_delivery",
        arguments: { delivery_id_value: deliveryId, lease_token_value: leaseToken },
      },
      {
        name: "invalidate_driver_push_device",
        arguments: { delivery_id_value: deliveryId, lease_token_value: leaseToken },
      },
      {
        name: "release_driver_push_delivery",
        arguments: { delivery_id_value: deliveryId, lease_token_value: leaseToken },
      },
    ]);
    expect(JSON.stringify(client.calls)).not.toContain("companyId");
  });
});
