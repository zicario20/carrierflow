import { operationalTokens } from "../../../../../../packages/design-tokens/src/tokens";
import {
  CurrentLocationMap,
  type AuthorizedCurrentLocation,
} from "../../../components/map/current-location-map";
import type { AdminLocale } from "../../../i18n/locale";
import { getRequestLocale } from "../../../i18n/request-locale";
import { createSupabaseServerClient } from "../../../lib/supabase/server";
import { getAuthenticatedDispatchContext } from "../../../server/dispatch/dispatch-context";
import { getAuthorizedCurrentLocation } from "../../../server/tracking/current-location-service";

type OperationsMapCopy = Readonly<{
  accuracy: string;
  coordinates: string;
  current: string;
  fallback: string;
  freshness: string;
  fresh: string;
  heading: string;
  lastUpdated: string;
  load: string;
  noLoad: string;
  onDuty: string;
  status: string;
  surface: string;
}>;

const copyByLocale: Readonly<Record<AdminLocale, OperationsMapCopy>> = {
  en: {
    accuracy: "Accuracy",
    coordinates: "Coordinates",
    current: "Authorized current location",
    fallback: "No authorized current location is available. The map is intentionally limited to current location when it is released by the tracking service.",
    fresh: "Current",
    freshness: "Freshness",
    heading: "Operations map",
    lastUpdated: "Last update",
    load: "Load context",
    noLoad: "No active load context",
    onDuty: "On duty",
    status: "Driver status",
    surface: "Current location surface",
  },
  es: {
    accuracy: "Precisión",
    coordinates: "Coordenadas",
    current: "Ubicación actual autorizada",
    fallback: "No hay una ubicación actual autorizada disponible. El mapa se limita intencionalmente a la ubicación actual cuando el servicio de seguimiento la publique.",
    fresh: "Actual",
    freshness: "Frescura",
    heading: "Mapa de operaciones",
    lastUpdated: "Última actualización",
    load: "Contexto de carga",
    noLoad: "No hay contexto de carga activo",
    onDuty: "De servicio",
    status: "Estado del conductor",
    surface: "Superficie de ubicación actual",
  },
};

const operationalStatusByLocale: Readonly<
  Record<AdminLocale, Readonly<Record<string, string>>>
> = {
  en: {
    assigned: "Assigned",
    arrived_delivery: "Arrived at delivery",
    arrived_pickup: "Arrived at pickup",
    en_route_to_delivery: "En route to delivery",
    en_route_to_pickup: "En route to pickup",
    loading: "Loading",
    picked_up: "Load picked up",
    unloading: "Unloading",
  },
  es: {
    assigned: "Asignada",
    arrived_delivery: "Llegó a entrega",
    arrived_pickup: "Llegó a recogida",
    en_route_to_delivery: "En camino a entrega",
    en_route_to_pickup: "En camino a recogida",
    loading: "Cargando",
    picked_up: "Carga recogida",
    unloading: "Descargando",
  },
};

function localizedOperationalStatus(
  status: string | null | undefined,
  locale: AdminLocale,
): string {
  if (status === null || status === undefined) return copyByLocale[locale].onDuty;
  return operationalStatusByLocale[locale][status] ?? "—";
}

export function OperationsMapContent({
  currentLocation,
  locale,
}: Readonly<{
  currentLocation: AuthorizedCurrentLocation | null;
  locale: AdminLocale;
}>) {
  const copy = copyByLocale[locale];
  const updatedAt = currentLocation === null
    ? null
    : new Intl.DateTimeFormat(locale === "en" ? "en-US" : "es-US", {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(new Date(currentLocation.recordedAt));

  return (
    <section aria-labelledby="operations-map-heading" style={{ display: "grid", gap: operationalTokens.spacing.section, maxWidth: "72rem" }}>
      <header>
        <h1 id="operations-map-heading">{copy.heading}</h1>
        <p style={mutedTextStyle}>{copy.surface}</p>
      </header>
      <section aria-labelledby="current-location-heading" style={surfaceStyle}>
        <h2 id="current-location-heading" style={{ marginTop: 0 }}>{copy.current}</h2>
        {currentLocation === null ? (
          <p role="status" style={mutedTextStyle}>{copy.fallback}</p>
        ) : (
          <>
            <dl style={detailsStyle}>
              <div>
                <dt style={termStyle}>{copy.status}</dt>
                <dd style={valueStyle}>{currentLocation.driverLabel} · {localizedOperationalStatus(currentLocation.operationalStatus, locale)}</dd>
              </div>
              <div>
                <dt style={termStyle}>{copy.lastUpdated}</dt>
                <dd style={valueStyle}>{updatedAt}</dd>
              </div>
              <div>
                <dt style={termStyle}>{copy.freshness}</dt>
                <dd style={valueStyle}>{copy.fresh}</dd>
              </div>
              <div>
                <dt style={termStyle}>{copy.accuracy}</dt>
                <dd style={valueStyle}>{currentLocation.accuracyMeters == null ? "—" : `${Math.round(currentLocation.accuracyMeters)} m`}</dd>
              </div>
              <div>
                <dt style={termStyle}>{copy.load}</dt>
                <dd style={valueStyle}>{currentLocation.loadNumber ?? copy.noLoad}</dd>
              </div>
              <div>
                <dt style={termStyle}>{copy.coordinates}</dt>
                <dd style={valueStyle}>
                  {currentLocation.latitude.toFixed(5)}, {currentLocation.longitude.toFixed(5)}
                </dd>
              </div>
            </dl>
            <CurrentLocationMap location={currentLocation} />
          </>
        )}
      </section>
    </section>
  );
}

export default async function OperationsMapPage() {
  const [locale, supabase] = await Promise.all([
    getRequestLocale(),
    createSupabaseServerClient(),
  ]);
  const context = await getAuthenticatedDispatchContext(supabase);
  const currentLocation = context === null
    ? null
    : await getAuthorizedCurrentLocation({
      client: supabase as never,
      companyId: context.companyId,
    });

  // The RLS-bound request client invokes a scoped RPC that returns exactly one
  // current point. History remains private and never reaches MapLibre.
  return <OperationsMapContent currentLocation={currentLocation} locale={locale} />;
}

const surfaceStyle = {
  backgroundColor: operationalTokens.color.surface,
  border: `1px solid ${operationalTokens.color.border}`,
  borderRadius: operationalTokens.radius.surface,
  padding: operationalTokens.spacing.comfortable,
} as const;

const mutedTextStyle = {
  color: operationalTokens.color.mutedForeground,
  margin: 0,
  maxWidth: "65ch",
} as const;

const detailsStyle = {
  display: "grid",
  gap: operationalTokens.spacing.comfortable,
  gridTemplateColumns: "repeat(auto-fit, minmax(14rem, 1fr))",
  margin: `0 0 ${operationalTokens.spacing.comfortable}`,
} as const;

const termStyle = {
  color: operationalTokens.color.mutedForeground,
  fontWeight: 600,
} as const;

const valueStyle = {
  fontVariantNumeric: "tabular-nums",
  fontWeight: 700,
  margin: 0,
} as const;
