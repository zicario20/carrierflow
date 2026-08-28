"use client";

import { useActionState, useEffect, useRef, useState } from "react";

import type { DispatchActionState } from "../../app/(ops)/loads/[loadId]/action-state";
import type { AdminLocale } from "../../i18n/locale";
import type { FleetDriver, FleetVehicle } from "../../server/fleet/fleet-service";
import { MileageBreakdown } from "./mileage-breakdown";

type DispatchAction = (state: DispatchActionState, formData: FormData) => Promise<DispatchActionState>;

const copy = {
  en: { assign: "Assign mandatory load", cancel: "Cancel load", confirmCancel: "Confirm cancellation", confirmText: "Cancel this load? This authorized action is recorded and cannot be undone here.", driver: "Driver", vehicle: "Vehicle", heading: "Dispatch controls", help: "Only authorized dispatch roles can assign, reassign, or cancel. Drivers cannot accept or reject loads.", keep: "Keep load", saving: "Saving…" },
  es: { assign: "Asignar carga obligatoria", cancel: "Cancelar carga", confirmCancel: "Confirmar cancelación", confirmText: "¿Cancelar esta carga? Esta acción autorizada se registra y no se puede deshacer aquí.", driver: "Conductor", vehicle: "Vehículo", heading: "Controles de despacho", help: "Solo los roles autorizados de despacho pueden asignar, reasignar o cancelar. Los conductores no pueden aceptar ni rechazar cargas.", keep: "Mantener carga", saving: "Guardando…" },
} as const;

export function LoadDispatchControls({ assignAction, cancelAction, currentStatus, drivers, loadId, locale, vehicles }: Readonly<{
  assignAction: DispatchAction;
  cancelAction: DispatchAction;
  currentStatus: string;
  drivers: readonly FleetDriver[];
  loadId: string;
  locale: AdminLocale;
  vehicles: readonly FleetVehicle[];
}>) {
  const labels = copy[locale];
  const [assignment, assignmentAction, assignmentPending] = useActionState(assignAction, { status: "idle" });
  const [cancellation, cancellationAction, cancellationPending] = useActionState(cancelAction, { status: "idle" });
  const [assignmentIntent, setAssignmentIntent] = useState<string | null>(null);
  const [cancellationIntent, setCancellationIntent] = useState<string | null>(null);
  const [confirmingCancellation, setConfirmingCancellation] = useState(false);
  const cancellationDialog = useRef<HTMLDialogElement>(null);
  const cancellationTrigger = useRef<HTMLButtonElement>(null);
  const confirmationButton = useRef<HTMLButtonElement>(null);
  useEffect(() => { setAssignmentIntent(crypto.randomUUID()); setCancellationIntent(crypto.randomUUID()); }, []);
  useEffect(() => { if (assignment.status === "success") setAssignmentIntent(crypto.randomUUID()); }, [assignment.status]);
  useEffect(() => { if (cancellation.status === "success") { setCancellationIntent(crypto.randomUUID()); setConfirmingCancellation(false); } }, [cancellation.status]);
  useEffect(() => {
    const dialog = cancellationDialog.current;
    if (!dialog) return;
    if (confirmingCancellation) {
      if (!dialog.open) {
        if (typeof dialog.showModal === "function") dialog.showModal();
        else dialog.setAttribute("open", "");
      }
      confirmationButton.current?.focus();
      return;
    }
    if (dialog.open) {
      if (typeof dialog.close === "function") dialog.close();
      else dialog.removeAttribute("open");
      cancellationTrigger.current?.focus();
    }
  }, [confirmingCancellation]);
  function dismissCancellationDialog() { setConfirmingCancellation(false); }
  function handleCancellationDialogClose() { setConfirmingCancellation(false); cancellationTrigger.current?.focus(); }
  function handleCancellationDialogCancel(event: React.SyntheticEvent<HTMLDialogElement>) {
    event.preventDefault();
    if (!cancellationPending) dismissCancellationDialog();
  }
  const isTerminal = currentStatus === "cancelled" || currentStatus === "closed" || currentStatus === "delivered";
  return (
    <section aria-labelledby="dispatch-controls-heading">
      <style>{dispatchControlsCss}</style>
      <h2 id="dispatch-controls-heading">{labels.heading}</h2>
      <p role="status">{labels.help}</p>
      <form action={assignmentAction} aria-busy={assignmentPending} style={{ display: "grid", gap: "0.75rem", maxWidth: "32rem" }}>
        <input name="loadId" type="hidden" value={loadId} />
        <input name="locale" type="hidden" value={locale} />
        <input name="intentKey" type="hidden" value={assignmentIntent ?? ""} />
        <label htmlFor="load-assignment-driver">{labels.driver}</label>
        <select className="carrierflow-dispatch-select" id="load-assignment-driver" name="driverId" required>
          <option value="">—</option>{drivers.filter((driver) => driver.status === "active").map((driver) => <option key={driver.id} value={driver.id}>{driver.displayName}</option>)}
        </select>
        <label htmlFor="load-assignment-vehicle">{labels.vehicle}</label>
        <select className="carrierflow-dispatch-select" id="load-assignment-vehicle" name="vehicleId" required>
          <option value="">—</option>{vehicles.filter((vehicle) => vehicle.status === "active").map((vehicle) => <option key={vehicle.id} value={vehicle.id}>{vehicle.unitNumber}</option>)}
        </select>
        <button className="carrierflow-control" disabled={assignmentPending || isTerminal || assignmentIntent === null} type="submit">{assignmentPending ? labels.saving : labels.assign}</button>
      </form>
      {assignment.message && <p role={assignment.status === "error" || assignment.status === "forbidden" ? "alert" : "status"}>{assignment.message}</p>}
      {assignment.routeStatus === "ready" && assignment.routeEstimate && <MileageBreakdown locale={locale} routeEstimate={assignment.routeEstimate} />}
      {!isTerminal && <button className="carrierflow-control" onClick={() => setConfirmingCancellation(true)} ref={cancellationTrigger} style={{ marginTop: "1rem" }} type="button">{labels.cancel}</button>}
      {!isTerminal && <dialog aria-describedby="cancel-confirmation-description" aria-labelledby="cancel-confirmation-heading" className="carrierflow-cancellation-dialog" onCancel={handleCancellationDialogCancel} onClose={handleCancellationDialogClose} ref={cancellationDialog}>
        <h3 id="cancel-confirmation-heading">{labels.confirmCancel}</h3>
        <p id="cancel-confirmation-description">{labels.confirmText}</p>
        <form action={cancellationAction} aria-busy={cancellationPending} style={{ display: "flex", flexWrap: "wrap", gap: "0.75rem" }}>
          <input name="loadId" type="hidden" value={loadId} />
          <input name="locale" type="hidden" value={locale} />
          <input name="intentKey" type="hidden" value={cancellationIntent ?? ""} />
          <button className="carrierflow-control carrierflow-destructive-control" disabled={cancellationPending || cancellationIntent === null} ref={confirmationButton} type="submit">{cancellationPending ? labels.saving : labels.confirmCancel}</button>
          <button className="carrierflow-control" disabled={cancellationPending} onClick={dismissCancellationDialog} type="button">{labels.keep}</button>
        </form>
      </dialog>}
      {cancellation.message && <p role={cancellation.status === "error" || cancellation.status === "forbidden" ? "alert" : "status"}>{cancellation.message}</p>}
    </section>
  );
}

const dispatchControlsCss = `
  .carrierflow-dispatch-select { background: var(--cf-color-surface); border: 1px solid var(--cf-color-border); border-radius: var(--cf-radius-control); color: var(--cf-color-foreground); font: inherit; min-block-size: var(--cf-control-target); padding-inline: var(--cf-space-standard); }
  .carrierflow-dispatch-select:focus-visible { outline: var(--cf-focus-ring-width) solid var(--cf-color-ring); outline-offset: var(--cf-focus-offset); }
  .carrierflow-cancellation-dialog { background: var(--cf-color-surface); border: 1px solid var(--cf-color-border); border-radius: var(--cf-radius-surface); color: var(--cf-color-foreground); max-inline-size: min(32rem, calc(100vw - 2rem)); padding: var(--cf-space-comfortable); }
  .carrierflow-cancellation-dialog::backdrop { background: color-mix(in srgb, var(--cf-color-foreground) 42%, transparent); }
  .carrierflow-destructive-control { background: var(--cf-color-destructive); border-color: var(--cf-color-destructive); color: var(--cf-color-on-destructive); }
  .carrierflow-destructive-control:hover { background: var(--cf-color-destructive); filter: brightness(.9); }
  @media (prefers-reduced-motion: reduce) { .carrierflow-dispatch-select, .carrierflow-destructive-control { transition: none; } }
`;
