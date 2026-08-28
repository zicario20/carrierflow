import { describe, expect, test } from "vitest";

import {
  FirebaseAdminPushSender,
  parseFirebaseServiceAccount,
} from "../src/server/notifications/firebase-admin-push-sender";

describe("Firebase Admin push sender", () => {
  test("sends a neutral brand-only OS alert plus only the opaque notification UUID", async () => {
    const messages: unknown[] = [];
    const sender = new FirebaseAdminPushSender({
      async send(message) {
        messages.push(message);
        return "provider-message-id";
      },
    });

    await sender.send("private-fcm-token", {
      data: { notificationId: "11111111-1111-4111-8111-111111111111" },
    });

    expect(messages).toEqual([
      {
        token: "private-fcm-token",
        data: { notificationId: "11111111-1111-4111-8111-111111111111" },
        notification: {
          title: "CarrierFlow",
        },
      },
    ]);
  });

  test("treats missing or malformed server-only service-account configuration as unavailable", () => {
    expect(parseFirebaseServiceAccount(undefined)).toBeNull();
    expect(parseFirebaseServiceAccount("not-json")).toBeNull();
    expect(parseFirebaseServiceAccount(JSON.stringify({ project_id: "project" }))).toBeNull();
  });
});
