import { describe, expect, test } from "vitest";

import {
  dispatchDriverRefreshHint,
  type ServerOnlyFcmTransport,
} from "../src/server/notifications/notification-service";

const notificationId = "11111111-1111-4111-8111-111111111111";

describe("minimal driver notification dispatch", () => {
  test("is an honest no-op when no server-only FCM transport is configured", async () => {
    await expect(dispatchDriverRefreshHint({ notificationId })).resolves.toEqual({
      status: "not_configured",
    });
  });

  test("sends only the private outbox identifier to an injected server-only transport", async () => {
    const sent: unknown[] = [];
    const transport: ServerOnlyFcmTransport = {
      async send(payload) {
        sent.push(payload);
      },
    };

    await expect(
      dispatchDriverRefreshHint({ notificationId, transport }),
    ).resolves.toEqual({ status: "sent" });
    expect(sent).toEqual([{ notificationId }]);
  });

  test("refuses a non-UUID identifier before a transport can be called", async () => {
    const transport: ServerOnlyFcmTransport = {
      async send() {
        throw new Error("must not send");
      },
    };

    await expect(
      dispatchDriverRefreshHint({ notificationId: "load-id-not-allowed", transport }),
    ).resolves.toEqual({ status: "invalid_event" });
  });
});
