import { describe, expect, test } from "vitest";

import {
  processOneDriverPushDelivery,
  type EncryptedDriverPushToken,
  type DriverPushDeliveryStore,
  type ServerOnlyDriverPushSender,
} from "../src/server/notifications/push-delivery-worker";

const workerId = "11111111-1111-4111-8111-111111111111";
type TestClaim = {
  deliveryId: string;
  encryptedToken: EncryptedDriverPushToken;
  leaseToken: string;
  notificationId: string;
};

const claim: TestClaim = {
  deliveryId: "22222222-2222-4222-8222-222222222222",
  encryptedToken: {
    ciphertext: Buffer.from("ciphertext-not-a-provider-token"),
    iv: Buffer.alloc(12, 1),
    authTag: Buffer.alloc(16, 2),
  },
  leaseToken: "33333333-3333-4333-8333-333333333333",
  notificationId: "44444444-4444-4444-8444-444444444444",
} as const;

class FakeStore implements DriverPushDeliveryStore {
  constructor(nextClaim: TestClaim | null) {
    this.nextClaim = nextClaim;
  }

  nextClaim: TestClaim | null;
  claims = 0;
  completed: Array<Pick<TestClaim, "deliveryId" | "leaseToken">> = [];
  invalidated: Array<Pick<TestClaim, "deliveryId" | "leaseToken">> = [];
  released: Array<Pick<TestClaim, "deliveryId" | "leaseToken">> = [];

  async claimNext(_workerId: string) {
    this.claims += 1;
    return this.nextClaim;
  }

  async complete(deliveryId: string, leaseToken: string) {
    this.completed.push({ deliveryId, leaseToken });
  }

  async invalidateDevice(deliveryId: string, leaseToken: string) {
    this.invalidated.push({ deliveryId, leaseToken });
  }

  async release(deliveryId: string, leaseToken: string) {
    this.released.push({ deliveryId, leaseToken });
  }
}

describe("server-only driver push delivery", () => {
  test("does not claim an outbox destination when no configured sender exists", async () => {
    const store = new FakeStore(claim);

    await expect(
      processOneDriverPushDelivery({ store, workerId }),
    ).resolves.toEqual({ status: "unavailable" });
    expect(store.claims).toBe(0);
  });

  test("sends only the opaque notification id through a configured private sender", async () => {
    const store = new FakeStore(claim);
    const sent: unknown[] = [];
    const sender: ServerOnlyDriverPushSender = {
      async send(destination, payload) {
        sent.push({ destination, payload });
      },
    };
    const decryptor = {
      decrypt: () => "private-provider-token-not-for-client-use",
    };

    await expect(
      processOneDriverPushDelivery({ store, sender, decryptor, workerId }),
    ).resolves.toEqual({ status: "delivered" });
    expect(sent).toEqual([
      {
        destination: "private-provider-token-not-for-client-use",
        payload: { data: { notificationId: claim.notificationId } },
      },
    ]);
    expect(store.completed).toEqual([
      { deliveryId: claim.deliveryId, leaseToken: claim.leaseToken },
    ]);
    expect(store.invalidated).toEqual([]);
  });

  test("invalidates a provider-rejected token instead of retrying it", async () => {
    const store = new FakeStore(claim);
    const sender: ServerOnlyDriverPushSender = {
      async send() {
        throw Object.assign(new Error("token expired"), {
          code: "messaging/registration-token-not-registered",
        });
      },
    };
    const decryptor = {
      decrypt: () => "private-provider-token-not-for-client-use",
    };

    await expect(
      processOneDriverPushDelivery({ store, sender, decryptor, workerId }),
    ).resolves.toEqual({ status: "invalidated" });
    expect(store.invalidated).toEqual([
      { deliveryId: claim.deliveryId, leaseToken: claim.leaseToken },
    ]);
    expect(store.released).toEqual([]);
  });

  test("releases a transient sender failure without exposing claim data", async () => {
    const store = new FakeStore(claim);
    const sender: ServerOnlyDriverPushSender = {
      async send() {
        throw new Error("transport unavailable");
      },
    };
    const decryptor = {
      decrypt: () => "private-provider-token-not-for-client-use",
    };

    await expect(
      processOneDriverPushDelivery({ store, sender, decryptor, workerId }),
    ).resolves.toEqual({ status: "retryable" });
    expect(store.released).toEqual([
      { deliveryId: claim.deliveryId, leaseToken: claim.leaseToken },
    ]);
  });

  test("does not claim when a configured sender lacks the server-only decryptor", async () => {
    const store = new FakeStore(claim);
    const sender: ServerOnlyDriverPushSender = { async send() {} };

    await expect(
      processOneDriverPushDelivery({ store, sender, workerId }),
    ).resolves.toEqual({ status: "unavailable" });
    expect(store.claims).toBe(0);
  });
});
