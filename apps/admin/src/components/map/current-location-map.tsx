"use client";

import "maplibre-gl/dist/maplibre-gl.css";

import { useEffect, useRef } from "react";
import { Map, Marker, type StyleSpecification } from "maplibre-gl";

import { operationalTokens } from "../../../../../packages/design-tokens/src/tokens";

export type AuthorizedCurrentLocation = Readonly<{
  accuracyMeters?: number;
  driverLabel: string;
  freshness?: "current";
  latitude: number;
  loadNumber?: string | null;
  longitude: number;
  operationalStatus?: string | null;
  recordedAt: string;
  status?: string;
}>;

const mapStyle: StyleSpecification = {
  layers: [{ id: "carrierflow-surface", paint: { "background-color": operationalTokens.color.background }, type: "background" }],
  sources: {},
  version: 8,
};

/**
 * Progressive enhancement only: server-rendered operational text stays the
 * source of truth, and this canvas receives one already-authorized current
 * point. It has no route, tile provider, API key, history, or track source.
 */
export function CurrentLocationMap({ location }: Readonly<{ location: AuthorizedCurrentLocation }>) {
  const container = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (container.current === null) {
      return undefined;
    }

    const map = new Map({
      attributionControl: false,
      center: [location.longitude, location.latitude],
      container: container.current,
      interactive: false,
      style: mapStyle,
      zoom: 11,
    });
    new Marker({ color: operationalTokens.color.primary })
      .setLngLat([location.longitude, location.latitude])
      .addTo(map);

    return () => map.remove();
  }, [location.latitude, location.longitude]);

  return (
    <div
      aria-hidden="true"
      ref={container}
      style={{
        border: `1px solid ${operationalTokens.color.border}`,
        borderRadius: operationalTokens.radius.surface,
        height: "18rem",
        width: "100%",
      }}
    />
  );
}
