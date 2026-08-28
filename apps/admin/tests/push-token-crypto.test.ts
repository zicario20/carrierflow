import { describe, expect, test } from "vitest";

import {
  decryptPushToken,
  encryptPushToken,
  parsePushTokenEncryptionKey,
} from "../src/server/notifications/push-token-crypto";

describe("server-only push-token cryptography", () => {
  test("round-trips a token with AES-256-GCM without retaining it in encrypted fields", () => {
    const token = "private-fcm-token-not-for-logs-abcdefghijklmnopqrstuvwxyz";
    const key = parsePushTokenEncryptionKey(
      "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
    );

    const encrypted = encryptPushToken(token, key);

    expect(decryptPushToken(encrypted, key)).toBe(token);
    expect(JSON.stringify(encrypted)).not.toContain(token);
    expect(encrypted.iv).toHaveLength(12);
    expect(encrypted.authTag).toHaveLength(16);
  });
});
