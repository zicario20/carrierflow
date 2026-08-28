import { describe, expect, test } from "vitest";

import {
  getAuthorizedCurrentLocation,
  type CurrentLocationReadClient,
} from "../src/server/tracking/current-location-service";

const companyId = "11111111-1111-1111-1111-111111111111";

describe("current location service", () => {
  test("reads exactly one manager-authorized current location through the scoped RPC", async () => {
    const calls: Array<Readonly<{ arguments: unknown; name: string }>> = [];
    const client: CurrentLocationReadClient = {
      async rpc(name, arguments_) {
        calls.push({ arguments: arguments_, name });
        return {
          data: {
            accuracyMeters: 8,
            driverLabel: "Avery Driver",
            latitude: 41.8781,
            loadNumber: "CF-100",
            longitude: -87.6298,
            operationalStatus: "en_route_to_delivery",
            recordedAt: "2026-08-28T12:00:00.000Z",
          },
          error: null,
        };
      },
    };

    await expect(
      getAuthorizedCurrentLocation({ client, companyId, now: new Date("2026-08-28T12:04:00.000Z") }),
    ).resolves.toEqual({
      accuracyMeters: 8,
      driverLabel: "Avery Driver",
      freshness: "current",
      latitude: 41.8781,
      loadNumber: "CF-100",
      longitude: -87.6298,
      operationalStatus: "en_route_to_delivery",
      recordedAt: "2026-08-28T12:00:00.000Z",
    });
    expect(calls).toEqual([
      {
        arguments: { target_company_id: companyId },
        name: "get_authorized_current_driver_location",
      },
    ]);
  });

  test("fails closed when the RPC reports an authorization error or malformed data", async () => {
    const denied: CurrentLocationReadClient = {
      async rpc() {
        return { data: null, error: { code: "42501" } };
      },
    };
    const malformed: CurrentLocationReadClient = {
      async rpc() {
        return {
          data: {
            accuracyMeters: -1,
            driverLabel: "Avery Driver",
            latitude: 41.8781,
            longitude: -87.6298,
            recordedAt: "not-a-date",
          },
          error: null,
        };
      },
    };

    await expect(getAuthorizedCurrentLocation({ client: denied, companyId })).resolves.toBeNull();
    await expect(getAuthorizedCurrentLocation({ client: malformed, companyId })).resolves.toBeNull();
  });

  test("fails closed rather than returning stale coordinates released by the RPC", async () => {
    const stale: CurrentLocationReadClient = {
      async rpc() {
        return {
          data: {
            accuracyMeters: 8,
            driverLabel: "Avery Driver",
            latitude: 41.8781,
            loadNumber: "CF-100",
            longitude: -87.6298,
            operationalStatus: "en_route_to_delivery",
            recordedAt: "2026-08-28T12:00:00.000Z",
          },
          error: null,
        };
      },
    };

    await expect(
      getAuthorizedCurrentLocation({ client: stale, companyId, now: new Date("2026-08-28T12:05:00.001Z") }),
    ).resolves.toBeNull();
  });

  test("returns null when the server releases no current location", async () => {
    const unavailable: CurrentLocationReadClient = {
      async rpc() {
        return { data: null, error: null };
      },
    };

    await expect(getAuthorizedCurrentLocation({ client: unavailable, companyId })).resolves.toBeNull();
  });
});
