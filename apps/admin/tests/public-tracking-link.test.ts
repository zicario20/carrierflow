import { describe, expect, test } from "vitest";

import {
  publicTrackingGetResponse,
  type PublicTrackingReadClient,
} from "../src/app/api/public/track/[token]/route";

const token = "a".repeat(64);

function clientReturning(data: unknown | null): PublicTrackingReadClient {
  return {
    async rpc(name, arguments_) {
      expect(name).toBe("resolve_public_load_tracking");
      expect(arguments_).toEqual({ token_value: token });
      return { data, error: null };
    },
  };
}

describe("public tracking route", () => {
  test("returns only the configured status, nullable ETA, and fresh opted-in current location", async () => {
    const response = await publicTrackingGetResponse({
      client: clientReturning({
        operationalStatus: "en_route_to_delivery",
        eta: null,
        currentLocation: {
          accuracyMeters: 8,
          latitude: 41.8781,
          longitude: -87.6298,
          recordedAt: "2026-08-28T12:00:00.000Z",
        },
        companyId: "must-not-pass-through",
        documents: ["private"],
        loadId: "must-not-pass-through",
      }),
      token,
      now: new Date("2026-08-28T12:04:00.000Z"),
    });

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    await expect(response.json()).resolves.toEqual({
      operationalStatus: "en_route_to_delivery",
      eta: null,
      currentLocation: {
        accuracyMeters: 8,
        latitude: 41.8781,
        longitude: -87.6298,
        recordedAt: "2026-08-28T12:00:00.000Z",
      },
    });
  });

  test("uses the same empty 404 response for malformed, unknown, expired, and revoked capabilities", async () => {
    const unavailable: PublicTrackingReadClient = {
      async rpc() {
        return { data: null, error: null };
      },
    };

    const malformed = await publicTrackingGetResponse({
      client: unavailable,
      token: "not-a-capability",
    });
    const unknownOrUnavailable = await publicTrackingGetResponse({
      client: unavailable,
      token,
    });

    expect(malformed.status).toBe(404);
    expect(unknownOrUnavailable.status).toBe(404);
    await expect(malformed.text()).resolves.toBe("");
    await expect(unknownOrUnavailable.text()).resolves.toBe("");
    expect(malformed.headers.get("cache-control")).toBe("no-store");
    expect(unknownOrUnavailable.headers.get("cache-control")).toBe("no-store");
  });

  test("fails closed when the server releases stale or malformed coordinates", async () => {
    const response = await publicTrackingGetResponse({
      client: clientReturning({
        operationalStatus: "en_route_to_pickup",
        eta: "2026-08-28T13:00:00.000Z",
        currentLocation: {
          accuracyMeters: 8,
          latitude: 41.8781,
          longitude: -87.6298,
          recordedAt: "2026-08-28T12:00:00.000Z",
        },
      }),
      token,
      now: new Date("2026-08-28T12:05:00.001Z"),
    });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      operationalStatus: "en_route_to_pickup",
      eta: "2026-08-28T13:00:00.000Z",
      currentLocation: null,
    });
  });
});
