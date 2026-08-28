import { describe, expect, test } from "vitest";

import { getConfiguredRoutingProvider } from "./configured-provider";

describe("configured OSRM routing provider", () => {
  test("is truthfully absent without a server URL", () => {
    expect(getConfiguredRoutingProvider({})).toBeNull();
  });

  test("uses only the validated server URL and returns a bounded non-truck-safe route summary", async () => {
    const requests: string[] = [];
    let requestRedirect: RequestRedirect | undefined;
    let requestSignal: AbortSignal | undefined;
    const provider = getConfiguredRoutingProvider(
      { ROUTING_PROVIDER_URL: "https://routing.internal/osrm" },
      async (input, init) => {
        requests.push(String(input));
        requestRedirect = init?.redirect;
        requestSignal = init?.signal ?? undefined;
        return new Response(JSON.stringify({ routes: [{ distance: 1609.344, duration: 95 }] }), { status: 200, headers: { "content-type": "application/json" } });
      },
    );
    expect(provider?.name).toBe("osrm");
    await expect(provider?.estimateRoute({ purpose: "loaded", waypoints: [{ id: "a", label: "A", latitude: 41.8, longitude: -87.6 }, { id: "b", label: "B", latitude: 42.3, longitude: -83.0 }] })).resolves.toEqual({ miles: "1.000", routeData: { distanceMeters: 1609, durationSeconds: 95 } });
    expect(requests[0]).toContain("https://routing.internal/route/v1/driving/-87.6,41.8;-83,42.3");
    expect(requestRedirect).toBe("error");
    expect(requestSignal).toBeInstanceOf(AbortSignal);
  });

  test("fails closed when a provider redirect is encountered", async () => {
    const provider = getConfiguredRoutingProvider(
      { ROUTING_PROVIDER_URL: "https://routing.internal/osrm" },
      async (_input, init) => {
        if (init?.redirect === "error") throw new TypeError("redirect blocked");
        return new Response(null, { headers: { location: "https://elsewhere.invalid" }, status: 302 });
      },
    );
    await expect(provider?.estimateRoute({ purpose: "empty", waypoints: [{ id: "a", label: "A", latitude: 41.8, longitude: -87.6 }, { id: "b", label: "B", latitude: 42.3, longitude: -83.0 }] })).rejects.toThrow("redirect blocked");
  });

  test("rejects an invalid server URL before it can become a request target", () => {
    expect(() => getConfiguredRoutingProvider({ ROUTING_PROVIDER_URL: "file:///etc/passwd" })).toThrow(/HTTP/);
  });
});
