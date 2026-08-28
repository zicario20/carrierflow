import "server-only";

import type { CompanyRole } from "../auth/authorize";
import {
  forbidden,
  ok,
  validationError,
  type MutationResult,
} from "../result";

export const loadOperationalStatuses = [
  "draft",
  "scheduled",
  "assigned",
  "en_route_to_pickup",
  "arrived_pickup",
  "loading",
  "picked_up",
  "en_route_to_delivery",
  "arrived_delivery",
  "unloading",
  "delivered",
  "closed",
  "cancelled",
] as const;

export type LoadOperationalStatus = (typeof loadOperationalStatuses)[number];

export const deliveryEvidenceTypes = [
  "photo",
  "receiver_name",
  "signature",
  "bol",
  "pod",
  "reference_number",
  "delivery_timestamp",
  "delivery_gps",
] as const;

export type DeliveryEvidenceType = (typeof deliveryEvidenceTypes)[number];

export const loadIncidentTypes = [
  "pickup_issue",
  "delivery_issue",
  "breakdown",
  "bad_address",
  "customer_unavailable",
  "site_rejected_load",
  "accident_emergency",
  "awaiting_instruction",
] as const;

export type LoadIncidentType = (typeof loadIncidentTypes)[number];

export type LoadDisplayLocale = "en" | "es";

const operationalStatusLabels: Readonly<Record<LoadOperationalStatus, Readonly<Record<LoadDisplayLocale, string>>>> = {
  draft: { en: "Draft", es: "Borrador" },
  scheduled: { en: "Scheduled", es: "Programada" },
  assigned: { en: "Assigned", es: "Asignada" },
  en_route_to_pickup: { en: "En route to pickup", es: "En camino a la recogida" },
  arrived_pickup: { en: "Arrived at pickup", es: "Llegó a la recogida" },
  loading: { en: "Loading", es: "Cargando" },
  picked_up: { en: "Picked up", es: "Carga recogida" },
  en_route_to_delivery: { en: "En route to delivery", es: "En camino a la entrega" },
  arrived_delivery: { en: "Arrived at delivery", es: "Llegó a la entrega" },
  unloading: { en: "Unloading", es: "Descargando" },
  delivered: { en: "Delivered", es: "Entregada" },
  closed: { en: "Closed", es: "Cerrada" },
  cancelled: { en: "Cancelled", es: "Cancelada" },
};

const incidentTypeLabels: Readonly<Record<LoadIncidentType, Readonly<Record<LoadDisplayLocale, string>>>> = {
  pickup_issue: { en: "Pickup issue", es: "Problema en recogida" },
  delivery_issue: { en: "Delivery issue", es: "Problema en entrega" },
  breakdown: { en: "Vehicle breakdown", es: "Vehículo averiado" },
  bad_address: { en: "Incorrect address", es: "Dirección incorrecta" },
  customer_unavailable: { en: "Customer unavailable", es: "Cliente no disponible" },
  site_rejected_load: { en: "Load rejected by facility", es: "Carga rechazada por el establecimiento" },
  accident_emergency: { en: "Accident or emergency", es: "Accidente o emergencia" },
  awaiting_instruction: { en: "Awaiting instructions", es: "Esperando instrucciones" },
};

/** Converts database enum values into the bilingual, operator-facing label. */
export function formatLoadOperationalStatus(
  status: LoadOperationalStatus,
  locale: LoadDisplayLocale,
): string {
  return operationalStatusLabels[status][locale];
}

/** Converts stored incident categories into clear bilingual operational copy. */
export function formatLoadIncidentType(
  incidentType: LoadIncidentType,
  locale: LoadDisplayLocale,
): string {
  return incidentTypeLabels[incidentType][locale];
}

type LoadMutationName = "advance_load_state" | "report_load_incident";

type RpcError = Readonly<{
  code?: string;
}>;

/**
 * This request-scoped client remains bound to the caller's JWT/RLS context.
 * Load writes use the narrow database RPCs; no service-role or table DML is
 * available from this module.
 */
export type TrustedLoadSupabaseClient = Readonly<{
  rpc: (
    functionName: LoadMutationName,
    arguments_: Readonly<Record<string, unknown>>,
  ) => Promise<Readonly<{ data: unknown | null; error: RpcError | null }>>;
}>;

export type LoadState = Readonly<{
  companyId: string;
  id: string;
  operationalStatus: LoadOperationalStatus;
}>;

export type LoadIncident = Readonly<{
  companyId: string;
  id: string;
  loadId: string;
  status: "open" | "resolved";
}>;

export type AdvanceLoadStateInput = Readonly<{
  actorRole: CompanyRole;
  client: TrustedLoadSupabaseClient;
  companyId: string;
  currentStatus: LoadOperationalStatus;
  loadId: string;
  nextStatus: LoadOperationalStatus;
}>;

export type ReportLoadIncidentInput = Readonly<{
  actorRole: CompanyRole;
  attachments: readonly string[];
  client: TrustedLoadSupabaseClient;
  companyId: string;
  description: string;
  incidentType: LoadIncidentType;
  loadId: string;
  location: Readonly<{ latitude: number; longitude: number }> | null;
}>;

const orderedTransitions: Readonly<Partial<Record<LoadOperationalStatus, LoadOperationalStatus>>> = {
  draft: "scheduled",
  scheduled: "assigned",
  assigned: "en_route_to_pickup",
  en_route_to_pickup: "arrived_pickup",
  arrived_pickup: "loading",
  loading: "picked_up",
  picked_up: "en_route_to_delivery",
  en_route_to_delivery: "arrived_delivery",
  arrived_delivery: "unloading",
  unloading: "delivered",
};

function isLoadOperationalStatus(value: unknown): value is LoadOperationalStatus {
  return typeof value === "string" && loadOperationalStatuses.includes(value as LoadOperationalStatus);
}

function isManager(role: CompanyRole): boolean {
  return role === "owner" || role === "admin" || role === "dispatcher";
}

function canAdvanceLoad(role: CompanyRole): boolean {
  return isManager(role) || role === "driver";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function parseLoadState(value: unknown): LoadState | null {
  if (!isRecord(value)) {
    return null;
  }
  const { company_id, id, operational_status } = value;
  if (
    typeof company_id !== "string" ||
    typeof id !== "string" ||
    !isLoadOperationalStatus(operational_status)
  ) {
    return null;
  }
  return { companyId: company_id, id, operationalStatus: operational_status };
}

function parseIncident(value: unknown): LoadIncident | null {
  if (!isRecord(value)) {
    return null;
  }
  const { company_id, id, load_id, status } = value;
  if (
    typeof company_id !== "string" ||
    typeof id !== "string" ||
    typeof load_id !== "string" ||
    (status !== "open" && status !== "resolved")
  ) {
    return null;
  }
  return { companyId: company_id, id, loadId: load_id, status };
}

function databaseFailure<T>(error: RpcError | null, message: string, field?: string): MutationResult<T> {
  return error?.code === "42501" ? forbidden() : validationError(message, field);
}

/** Returns required delivery evidence that is still absent; photos remain optional by policy. */
export function missingRequiredDeliveryEvidence(input: Readonly<{
  requirements: readonly DeliveryEvidenceType[];
  submittedEvidence: readonly DeliveryEvidenceType[];
}>): readonly DeliveryEvidenceType[] {
  const submitted = new Set(input.submittedEvidence);
  return input.requirements.filter(
    (requirement) => requirement !== "photo" && !submitted.has(requirement),
  );
}

/**
 * Performs a local ordered-state preflight for clear feedback, then delegates
 * authorization, tenant ownership, evidence checks, auditing and persistence
 * to the transactionally enforced database RPC.
 */
export async function advanceLoadState(
  input: AdvanceLoadStateInput,
): Promise<MutationResult<LoadState>> {
  if (!canAdvanceLoad(input.actorRole)) {
    return forbidden();
  }

  if (input.nextStatus === "delivered" && input.currentStatus !== "unloading") {
    return validationError(
      "A load must be picked up before it can be delivered.",
      "status",
    );
  }

  if (input.nextStatus === "cancelled" && isManager(input.actorRole)) {
    const response = await input.client.rpc("advance_load_state", {
      target_company_id: input.companyId,
      target_load_id: input.loadId,
      target_operational_status: input.nextStatus,
    });
    if (response.error) return databaseFailure(response.error, "The load state transition was rejected.", "status");
    const state = parseLoadState(response.data);
    return state ? ok(state) : validationError("The load state transition was rejected.", "status");
  }

  if (orderedTransitions[input.currentStatus] !== input.nextStatus) {
    return validationError("The load must follow its ordered operational states.", "status");
  }

  const response = await input.client.rpc("advance_load_state", {
    target_company_id: input.companyId,
    target_load_id: input.loadId,
    target_operational_status: input.nextStatus,
  });
  if (response.error) {
    return databaseFailure(response.error, "The load state transition was rejected.", "status");
  }
  const state = parseLoadState(response.data);
  return state ? ok(state) : validationError("The load state transition was rejected.", "status");
}

/**
 * Incidents are intentionally a separate RPC. It receives no target state,
 * so it cannot cancel or advance a load as a side effect.
 */
export async function reportLoadIncident(
  input: ReportLoadIncidentInput,
): Promise<MutationResult<LoadIncident>> {
  if (!canAdvanceLoad(input.actorRole)) {
    return forbidden();
  }
  if (input.description.trim().length === 0) {
    return validationError("An incident description is required.", "description");
  }

  const response = await input.client.rpc("report_load_incident", {
    incident_attachments: input.attachments,
    incident_description: input.description,
    incident_location: input.location,
    incident_type_value: input.incidentType,
    target_company_id: input.companyId,
    target_load_id: input.loadId,
  });
  if (response.error) {
    return databaseFailure(response.error, "The incident could not be reported.", "incident");
  }
  const incident = parseIncident(response.data);
  return incident ? ok(incident) : validationError("The incident could not be reported.", "incident");
}
