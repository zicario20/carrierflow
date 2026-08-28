import { notFound } from "next/navigation";

import { operationalTokens } from "../../../../../../../packages/design-tokens/src/tokens";
import { getRequestLocale } from "../../../../i18n/request-locale";
import { createSupabaseServerClient } from "../../../../lib/supabase/server";
import { LoadDispatchControls } from "../../../../components/loads/load-dispatch-controls";
import { getAuthenticatedDispatchContext } from "../../../../server/dispatch/dispatch-context";
import { listDrivers, listVehicles } from "../../../../server/fleet/fleet-service";
import {
  formatLoadIncidentType,
  formatLoadOperationalStatus,
  type LoadIncidentType,
  type LoadOperationalStatus,
} from "../../../../server/loads/load-service";
import { assignLoadResourcesAction, cancelLoadAction } from "./actions";

type LoadDetailCopy = Readonly<{
  backToLoads: string;
  delivery: string;
  evidence: string;
  heading: string;
  incident: string;
  noEvidence: string;
  noIncidents: string;
  pickup: string;
  readOnly: string;
  sequence: string;
  status: string;
  stops: string;
}>;

const copyByLocale: Readonly<Record<"en" | "es", LoadDetailCopy>> = {
  en: {
    backToLoads: "Back to loads",
    delivery: "Delivery",
    evidence: "Delivery evidence requirements",
    heading: "Load details",
    incident: "Open incident",
    noEvidence: "No delivery evidence is required yet.",
    noIncidents: "No incidents have been reported.",
    pickup: "Pickup",
    readOnly: "Operational record. Authorized dispatch actions are audited on the server.",
    sequence: "Stop",
    status: "Operational status",
    stops: "Stops",
  },
  es: {
    backToLoads: "Volver a cargas",
    delivery: "Entrega",
    evidence: "Requisitos de evidencia de entrega",
    heading: "Detalles de la carga",
    incident: "Incidencia abierta",
    noEvidence: "Todavía no se requiere evidencia de entrega.",
    noIncidents: "No se han reportado incidencias.",
    pickup: "Recogida",
    readOnly: "Registro operativo. Las acciones autorizadas de despacho se auditan en el servidor.",
    sequence: "Parada",
    status: "Estado operativo",
    stops: "Paradas",
  },
};

type LoadStop = Readonly<{
  country_code: string;
  sequence: number;
  stop_data: Readonly<{ address?: string; businessName?: string }>;
  stop_type: "pickup" | "delivery";
  timezone_name: string;
}>;

type LoadEvidenceRequirement = Readonly<{
  requirement_type: string;
}>;

type LoadIncident = Readonly<{
  description: string;
  incident_type: LoadIncidentType;
  status: "open" | "resolved";
}>;

type LoadDetail = Readonly<{
  load_evidence_requirements: readonly LoadEvidenceRequirement[] | null;
  load_incidents: readonly LoadIncident[] | null;
  load_number: string;
  load_stops: readonly LoadStop[] | null;
  operational_status: LoadOperationalStatus;
}>;

function stopLabel(stopType: LoadStop["stop_type"], copy: LoadDetailCopy): string {
  return stopType === "pickup" ? copy.pickup : copy.delivery;
}

function formatRequirement(requirement: string, locale: "en" | "es"): string {
  const labels: Record<string, readonly [string, string]> = {
    bol: ["Bill of Lading", "Conocimiento de embarque"],
    delivery_gps: ["Delivery GPS", "GPS de entrega"],
    delivery_timestamp: ["Delivery timestamp", "Fecha y hora de entrega"],
    photo: ["Photo", "Fotografía"],
    pod: ["Proof of delivery", "Comprobante de entrega"],
    receiver_name: ["Receiver name", "Nombre del receptor"],
    reference_number: ["Reference number", "Número de referencia"],
    signature: ["Signature", "Firma"],
  };
  return labels[requirement]?.[locale === "en" ? 0 : 1] ?? requirement;
}

export default async function LoadDetailPage({
  params,
}: Readonly<{
  params: Promise<Readonly<{ loadId: string }>>;
}>) {
  const [{ loadId }, locale, supabase] = await Promise.all([
    params,
    getRequestLocale(),
    createSupabaseServerClient(),
  ]);
  const copy = copyByLocale[locale];
  const { data, error } = await supabase
    .from("loads")
    .select(
      "load_number, operational_status, load_stops(sequence, stop_type, stop_data, country_code, timezone_name), load_evidence_requirements(requirement_type), load_incidents(incident_type, description, status)",
    )
    .eq("id", loadId)
    .maybeSingle();

  // The RLS-bound request client makes missing and unauthorized records
  // indistinguishable, so this page never leaks cross-company load existence.
  if (error || !data) {
    notFound();
  }

  const load = data as LoadDetail;
  const stops = [...(load.load_stops ?? [])].sort((left, right) => left.sequence - right.sequence);
  const requirements = load.load_evidence_requirements ?? [];
  const incidents = (load.load_incidents ?? []).filter((incident) => incident.status === "open");
  const context = await getAuthenticatedDispatchContext(supabase);
  const [drivers, vehicles] = context === null ? [null, null] : await Promise.all([
    listDrivers({ client: supabase as never, companyId: context.companyId }),
    listVehicles({ client: supabase as never, companyId: context.companyId }),
  ]);

  return (
    <section aria-labelledby="load-detail-heading" style={{ maxWidth: "72rem" }}>
      <a className="carrierflow-control" href="/loads" style={{ marginBottom: operationalTokens.spacing.comfortable }}>
        {copy.backToLoads}
      </a>
      <header
        style={{
          alignItems: "baseline",
          display: "flex",
          flexWrap: "wrap",
          gap: operationalTokens.spacing.comfortable,
          justifyContent: "space-between",
          marginBottom: operationalTokens.spacing.section,
        }}
      >
        <div>
          <p style={{ color: operationalTokens.color.mutedForeground, margin: 0 }}>{copy.heading}</p>
          <h1 id="load-detail-heading" style={{ marginBottom: 0 }}>
            {load.load_number}
          </h1>
        </div>
        <p
          aria-label={`${copy.status}: ${formatLoadOperationalStatus(load.operational_status, locale)}`}
          style={{
            backgroundColor: operationalTokens.color.muted,
            borderRadius: operationalTokens.radius.control,
            color: operationalTokens.color.foreground,
            fontWeight: 700,
            margin: 0,
            padding: `${operationalTokens.spacing.standard} ${operationalTokens.spacing.comfortable}`,
          }}
        >
          {copy.status}: {formatLoadOperationalStatus(load.operational_status, locale)}
        </p>
      </header>
      <p
        role="status"
        style={{ color: operationalTokens.color.mutedForeground, marginBottom: operationalTokens.spacing.section, maxWidth: "65ch" }}
      >
        {copy.readOnly}
      </p>

      {context !== null && drivers?.ok && vehicles?.ok && (
        <section style={sectionStyle}>
          <LoadDispatchControls
            assignAction={assignLoadResourcesAction}
            cancelAction={cancelLoadAction}
            currentStatus={load.operational_status}
            drivers={drivers.data}
            loadId={loadId}
            locale={locale}
            vehicles={vehicles.data}
          />
        </section>
      )}

      <section aria-labelledby="load-stops-heading" style={sectionStyle}>
        <h2 id="load-stops-heading" style={headingStyle}>{copy.stops}</h2>
        <ol style={{ display: "grid", gap: operationalTokens.spacing.standard, margin: 0, paddingLeft: "1.5rem" }}>
          {stops.map((stop) => (
            <li key={`${stop.stop_type}-${stop.sequence}`}>
              <strong>{copy.sequence} {stop.sequence}: {stopLabel(stop.stop_type, copy)}</strong>
              <p style={detailTextStyle}>{stop.stop_data.businessName ?? stop.stop_data.address ?? "—"}</p>
              {stop.stop_data.businessName && <p style={detailTextStyle}>{stop.stop_data.address ?? "—"}</p>}
              <p style={detailTextStyle}>{stop.country_code} · {stop.timezone_name}</p>
            </li>
          ))}
        </ol>
      </section>

      <section aria-labelledby="load-evidence-heading" style={sectionStyle}>
        <h2 id="load-evidence-heading" style={headingStyle}>{copy.evidence}</h2>
        {requirements.length === 0 ? (
          <p style={detailTextStyle}>{copy.noEvidence}</p>
        ) : (
          <ul style={{ display: "grid", gap: operationalTokens.spacing.compact, margin: 0, paddingLeft: "1.5rem" }}>
            {requirements.map((requirement) => (
              <li key={requirement.requirement_type}>{formatRequirement(requirement.requirement_type, locale)}</li>
            ))}
          </ul>
        )}
      </section>

      <section aria-labelledby="load-incidents-heading" style={sectionStyle}>
        <h2 id="load-incidents-heading" style={headingStyle}>{copy.incident}</h2>
        {incidents.length === 0 ? (
          <p style={detailTextStyle}>{copy.noIncidents}</p>
        ) : (
          <ul style={{ display: "grid", gap: operationalTokens.spacing.standard, margin: 0, paddingLeft: "1.5rem" }}>
            {incidents.map((incident, index) => (
              <li key={`${incident.incident_type}-${index}`}>
                <strong>{formatLoadIncidentType(incident.incident_type, locale)}</strong>
                <p style={detailTextStyle}>{incident.description}</p>
              </li>
            ))}
          </ul>
        )}
      </section>
    </section>
  );
}

const sectionStyle = {
  backgroundColor: operationalTokens.color.surface,
  border: `1px solid ${operationalTokens.color.border}`,
  borderRadius: operationalTokens.radius.surface,
  marginBottom: operationalTokens.spacing.comfortable,
  padding: operationalTokens.spacing.comfortable,
} as const;

const headingStyle = {
  marginTop: 0,
} as const;

const detailTextStyle = {
  color: operationalTokens.color.mutedForeground,
  marginBottom: operationalTokens.spacing.compact,
  marginTop: operationalTokens.spacing.compact,
} as const;
