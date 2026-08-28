import { describe, expect, test } from "vitest";

import { internalPushDispatchResponse } from "../src/app/api/internal/push/dispatch/route";

describe("protected push dispatch route", () => {
  test("denies missing or incorrect worker headers without invoking a claim worker", async () => {
    let runs = 0;
    const run = async () => {
      runs += 1;
      return { status: "idle" as const };
    };

    for (const header of [undefined, "wrong-secret"]) {
      const response = await internalPushDispatchResponse(
        new Request("https://admin.carrierflow.test/api/internal/push/dispatch", {
          method: "POST",
          headers: header ? { "x-carrierflow-push-worker-secret": header } : undefined,
        }),
        { workerSecret: "correct-secret", run },
      );
      expect(response.status).toBe(401);
      await expect(response.json()).resolves.toEqual({ error: "unauthorized" });
    }
    expect(runs).toBe(0);
  });

  test("accepts a constant-time protected worker invocation and exposes no claim material", async () => {
    const response = await internalPushDispatchResponse(
      new Request("https://admin.carrierflow.test/api/internal/push/dispatch", {
        method: "POST",
        headers: { "x-carrierflow-push-worker-secret": "correct-secret" },
      }),
      {
        workerSecret: "correct-secret",
        run: async () => ({ status: "delivered" as const }),
      },
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    await expect(response.json()).resolves.toEqual({ status: "delivered" });
  });
});
