import { describe, expect, test } from "vitest";

import {
  pushDeviceRegistrationResponse,
  isPushDeliveryRuntimeConfigured,
  type BearerUserVerifier,
  type EncryptedPushDeviceWriter,
} from "../src/app/api/driver/push-device/route";

const key = Buffer.from("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", "hex");
const userOne = "11111111-1111-4111-8111-111111111111";
const userTwo = "22222222-2222-4222-8222-222222222222";
const token = "private-fcm-token-abcdefghijklmnopqrstuvwxyz";

class FakeVerifier implements BearerUserVerifier {
  calls: string[] = [];

  async getUser(accessToken: string) {
    this.calls.push(accessToken);
    return accessToken === "session-for-user-one" ? { id: userOne } : null;
  }
}

class FakeWriter implements EncryptedPushDeviceWriter {
  calls: Array<{ targetUserId: string; tokenHash: Buffer; ciphertext: Buffer; iv: Buffer; authTag: Buffer; platform: string }> = [];

  async register(value: { targetUserId: string; tokenHash: Buffer; ciphertext: Buffer; iv: Buffer; authTag: Buffer; platform: string }) {
    this.calls.push(value);
  }
}

describe("driver push-device registration endpoint", () => {
  test("verifies the bearer with auth.getUser and writes only an encrypted server envelope for that session user", async () => {
    const verifier = new FakeVerifier();
    const writer = new FakeWriter();
    const request = new Request("https://admin.carrierflow.test/api/driver/push-device", {
      method: "POST",
      headers: {
        authorization: "Bearer session-for-user-one",
        "content-type": "application/json",
      },
      body: JSON.stringify({ pushToken: token, platform: "android", userId: userTwo }),
    });

    const response = await pushDeviceRegistrationResponse(request, {
      verifier,
      writer,
      encryptionKey: key,
      deliveryConfigured: true,
    });

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    await expect(response.json()).resolves.toEqual({ registered: true });
    expect(verifier.calls).toEqual(["session-for-user-one"]);
    expect(writer.calls).toHaveLength(1);
    const [registered] = writer.calls;
    expect(registered).toBeDefined();
    expect(registered).toMatchObject({
      targetUserId: userOne,
      platform: "android",
    });
    expect(registered!.ciphertext.equals(Buffer.from(token))).toBe(false);
    expect(JSON.stringify(registered)).not.toContain(token);
  });

  test("uses the same unauthenticated HTTP result for missing and invalid bearer sessions", async () => {
    const verifier = new FakeVerifier();
    const writer = new FakeWriter();

    for (const authorization of [undefined, "Bearer session-for-other-user"]) {
      const response = await pushDeviceRegistrationResponse(
        new Request("https://admin.carrierflow.test/api/driver/push-device", {
          method: "POST",
          headers: authorization ? { authorization } : undefined,
        }),
        { verifier, writer, encryptionKey: key, deliveryConfigured: true },
      );
      expect(response.status).toBe(401);
      await expect(response.json()).resolves.toEqual({ error: "unauthorized" });
    }
    expect(writer.calls).toEqual([]);
  });

  test("does not acknowledge a device as registered when FCM delivery prerequisites are unavailable", async () => {
    const verifier = new FakeVerifier();
    const writer = new FakeWriter();
    const request = new Request("https://admin.carrierflow.test/api/driver/push-device", {
      method: "POST",
      headers: {
        authorization: "Bearer session-for-user-one",
        "content-type": "application/json",
      },
      body: JSON.stringify({ pushToken: token, platform: "ios" }),
    });

    const response = await pushDeviceRegistrationResponse(request, {
      verifier,
      writer,
      encryptionKey: key,
      deliveryConfigured: false,
    });

    expect(response.status).toBe(503);
    expect(response.headers.get("cache-control")).toBe("no-store");
    await expect(response.json()).resolves.toEqual({ error: "unavailable" });
    expect(writer.calls).toEqual([]);
  });

  test("requires both an FCM service account and a private worker secret for delivery configuration", () => {
    const fcmServiceAccount = JSON.stringify({
      project_id: "carrierflow-test",
      client_email: "fcm@carrierflow.test",
      private_key: "-----BEGIN PRIVATE KEY-----\\nnot-a-real-key\\n-----END PRIVATE KEY-----",
    });

    expect(isPushDeliveryRuntimeConfigured({})).toBe(false);
    expect(isPushDeliveryRuntimeConfigured({ FCM_SERVICE_ACCOUNT_JSON: fcmServiceAccount })).toBe(false);
    expect(isPushDeliveryRuntimeConfigured({ PUSH_WORKER_SECRET: "private-worker-secret" })).toBe(false);
    expect(isPushDeliveryRuntimeConfigured({
      FCM_SERVICE_ACCOUNT_JSON: fcmServiceAccount,
      PUSH_WORKER_SECRET: "private-worker-secret",
    })).toBe(true);
  });
});
