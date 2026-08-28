"use server";

import { revalidatePath } from "next/cache";

import { createSupabaseServerClient } from "../../../../lib/supabase/server";
import { getAuthenticatedDispatchContext } from "../../../../server/dispatch/dispatch-context";
import { submitAuthorizedLoadProposal, type LoadProposalInput } from "../../../../server/dispatch/proposal-service";
import type { ProposalActionState } from "./action-state";

function formValue(formData: FormData, name: "delivery" | "loadNumber" | "pickup" | "quoteUsd"): string {
  const value = formData.get(name);
  return typeof value === "string" ? value : "";
}
function intentKey(formData: FormData): string { return typeof formData.get("intentKey") === "string" ? formData.get("intentKey") as string : ""; }

function localized(formData: FormData, english: string, spanish: string): string {
  return formData.get("locale") === "es" ? spanish : english;
}

export async function createLoadProposalAction(
  _previous: ProposalActionState,
  formData: FormData,
): Promise<ProposalActionState> {
    const client = await createSupabaseServerClient();
    const context = await getAuthenticatedDispatchContext(client);
    if (!context) return { message: localized(formData, "You do not have permission to perform this action.", "No tienes permiso para realizar esta acción."), status: "forbidden" };
    const result = await submitAuthorizedLoadProposal({
      client: client as never,
      companyId: context.companyId,
      intentKey: intentKey(formData),
      proposal: {
        delivery: formValue(formData, "delivery"),
        loadNumber: formValue(formData, "loadNumber"),
        pickup: formValue(formData, "pickup"),
        quoteUsd: formValue(formData, "quoteUsd"),
      },
    });
    if (!result.ok) return {
      field: result.error.code === "validation" ? result.error.field : undefined,
      message: result.error.code === "forbidden"
        ? localized(formData, "You do not have permission to perform this action.", "No tienes permiso para realizar esta acción.")
        : localized(formData, "The proposal could not be saved safely. Review the marked field and try again.", "La propuesta no se pudo guardar de forma segura. Revisa el campo marcado e inténtalo de nuevo."),
      status: result.error.code === "forbidden" ? "forbidden" : "error",
    };
    revalidatePath("/loads");
    revalidatePath(`/loads/${result.data.loadId}`);
    return { loadId: result.data.loadId, message: localized(formData, "Load proposal saved. Assign a driver and vehicle before routing begins.", "Propuesta guardada. Asigna un conductor y vehículo antes de iniciar la ruta."), routeStatus: "assignment_required", status: "success" };
}
