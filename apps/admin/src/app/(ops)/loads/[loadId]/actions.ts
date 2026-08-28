"use server";

import { revalidatePath } from "next/cache";

import { createSupabaseServerClient } from "../../../../lib/supabase/server";
import { assignLoadResources, cancelLoadIdempotently } from "../../../../server/dispatch/assignment-service";
import { getAuthenticatedDispatchContext } from "../../../../server/dispatch/dispatch-context";
import { getConfiguredRoutingProvider } from "../../../../server/routing/configured-provider";
import type { DispatchActionState } from "./action-state";

function value(formData: FormData, name: string): string { const item = formData.get(name); return typeof item === "string" ? item : ""; }
function localized(formData: FormData, english: string, spanish: string): string { return value(formData, "locale") === "es" ? spanish : english; }

export async function assignLoadResourcesAction(_previous: DispatchActionState, formData: FormData): Promise<DispatchActionState> {
  const client = await createSupabaseServerClient();
  const context = await getAuthenticatedDispatchContext(client);
  if (!context) return { message: localized(formData, "You do not have permission to perform this action.", "No tienes permiso para realizar esta acción."), status: "forbidden" };
  const loadId = value(formData, "loadId");
  const result = await assignLoadResources({ client: client as never, companyId: context.companyId, driverId: value(formData, "driverId"), idempotencyKey: value(formData, "intentKey"), loadId, routingProvider: getConfiguredRoutingProvider(), vehicleId: value(formData, "vehicleId") });
  if (!result.ok) return { message: result.error.code === "forbidden" ? localized(formData, "You do not have permission to perform this action.", "No tienes permiso para realizar esta acción.") : localized(formData, "The mandatory assignment was rejected by the server.", "La asignación obligatoria fue rechazada por el servidor."), status: result.error.code === "forbidden" ? "forbidden" : "error" };
  revalidatePath("/loads"); revalidatePath(`/loads/${loadId}`);
  return result.data.routeStatus === "ready" && result.data.revision
    ? { message: localized(formData, "Mandatory load assignment saved and the route estimate is ready.", "Asignación obligatoria guardada y la estimación de ruta está lista."), routeEstimate: result.data.revision, routeStatus: "ready", status: "success" }
    : { message: localized(formData, "Mandatory load assignment saved. Routing is pending an approved server result.", "Asignación obligatoria guardada. La ruta está pendiente de un resultado aprobado por el servidor."), routeStatus: "pending", status: "success" };
}

export async function cancelLoadAction(_previous: DispatchActionState, formData: FormData): Promise<DispatchActionState> {
  const client = await createSupabaseServerClient();
  const context = await getAuthenticatedDispatchContext(client);
  if (!context) return { message: localized(formData, "You do not have permission to perform this action.", "No tienes permiso para realizar esta acción."), status: "forbidden" };
  const loadId = value(formData, "loadId");
  const result = await cancelLoadIdempotently({ client: client as never, companyId: context.companyId, idempotencyKey: value(formData, "intentKey"), loadId });
  if (!result.ok) return { message: result.error.code === "forbidden" ? localized(formData, "You do not have permission to perform this action.", "No tienes permiso para realizar esta acción.") : localized(formData, "The cancellation was rejected by the server.", "La cancelación fue rechazada por el servidor."), status: result.error.code === "forbidden" ? "forbidden" : "error" };
  revalidatePath("/loads"); revalidatePath(`/loads/${loadId}`);
  return { message: localized(formData, "Load cancelled and audited.", "Carga cancelada y auditada."), status: "success" };
}
