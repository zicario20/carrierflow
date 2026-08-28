import "server-only";

import type { ServerRoutingProvider } from "./routing-provider";

const maximumResponseBytes = 65_536;
const maximumDistanceMeters = 5_000_000;
const maximumDurationSeconds = 604_800;
const networkTimeoutMs = 10_000;
const metersPerMile = 1609.344;

type Fetcher = typeof fetch;

function serverRoutingUrl(value: string): URL {
  let url: URL;
  try { url = new URL(value); } catch { throw new Error("ROUTING_PROVIDER_URL must be an absolute HTTP(S) URL"); }
  if ((url.protocol !== "http:" && url.protocol !== "https:") || url.username || url.password || url.hash) {
    throw new Error("ROUTING_PROVIDER_URL must be an absolute HTTP(S) URL without credentials or fragments");
  }
  return url;
}

function routeUrl(base: URL, coordinates: string): URL {
  const url = new URL(`/route/v1/driving/${coordinates}`, base);
  url.searchParams.set("alternatives", "false");
  url.searchParams.set("overview", "false");
  url.searchParams.set("steps", "false");
  return url;
}

function parseRoute(body: unknown): Readonly<{ distanceMeters: number; durationSeconds: number }> {
  if (!body || typeof body !== "object" || !Array.isArray((body as { routes?: unknown }).routes)) throw new Error("OSRM returned an invalid route response");
  const route = (body as { routes: unknown[] }).routes[0];
  if (!route || typeof route !== "object") throw new Error("OSRM returned an invalid route response");
  const { distance, duration } = route as { distance?: unknown; duration?: unknown };
  if (typeof distance !== "number" || !Number.isFinite(distance) || distance < 0 || distance > maximumDistanceMeters || typeof duration !== "number" || !Number.isFinite(duration) || duration < 0 || duration > maximumDurationSeconds) throw new Error("OSRM returned an unsafe route response");
  return { distanceMeters: Math.round(distance), durationSeconds: Math.round(duration) };
}

function fixedTimeoutSignal(parent: AbortSignal | undefined): Readonly<{ dispose: () => void; signal: AbortSignal }> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  const timeout = setTimeout(abort, networkTimeoutMs);
  if (parent?.aborted) abort();
  else parent?.addEventListener("abort", abort, { once: true });
  return {
    signal: controller.signal,
    dispose: () => {
      clearTimeout(timeout);
      parent?.removeEventListener("abort", abort);
    },
  };
}

/**
 * An optional, server-only OSRM adapter. It accepts no user URL, credentials
 * or truck-safety claim; it produces ordinary route estimates only.
 */
export function getConfiguredRoutingProvider(
  environment: Readonly<Record<string, string | undefined>> = process.env,
  fetcher: Fetcher = fetch,
): ServerRoutingProvider | null {
  const rawUrl = environment.ROUTING_PROVIDER_URL?.trim();
  if (!rawUrl) return null;
  const base = serverRoutingUrl(rawUrl);
  return {
    name: "osrm",
    async estimateRoute(request, options) {
      if (request.waypoints.length < 2 || request.waypoints.length > 16) throw new Error("OSRM requires between two and sixteen route points");
      const coordinates = request.waypoints.map((point) => {
        if (!Number.isFinite(point.latitude) || !Number.isFinite(point.longitude) || point.latitude < -90 || point.latitude > 90 || point.longitude < -180 || point.longitude > 180) throw new Error("OSRM received an invalid route point");
        return `${point.longitude},${point.latitude}`;
      }).join(";");
      const timeout = fixedTimeoutSignal(options?.signal);
      let response: Response;
      try {
        response = await fetcher(routeUrl(base, coordinates), { headers: { accept: "application/json" }, redirect: "error", signal: timeout.signal });
      } finally {
        timeout.dispose();
      }
      if (!response.ok) throw new Error("OSRM route request failed");
      const length = Number(response.headers.get("content-length") ?? "0");
      if (!Number.isFinite(length) || length > maximumResponseBytes) throw new Error("OSRM route response is too large");
      const raw = await response.text();
      if (new TextEncoder().encode(raw).byteLength > maximumResponseBytes) throw new Error("OSRM route response is too large");
      const summary = parseRoute(JSON.parse(raw));
      return { miles: (summary.distanceMeters / metersPerMile).toFixed(3), routeData: summary };
    },
  };
}
