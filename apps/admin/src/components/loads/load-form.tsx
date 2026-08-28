"use client";

import { useActionState, useEffect, useState } from "react";

import { operationalTokens } from "../../../../../packages/design-tokens/src/tokens";
import type { AdminLocale } from "../../i18n/locale";
import type { ProposalActionState } from "../../app/(ops)/loads/new/action-state";
import { MileageBreakdown } from "./mileage-breakdown";

type ProposalField = "delivery" | "loadNumber" | "pickup" | "quoteUsd";

type ProposalValues = Record<ProposalField, string>;

export type LoadProposalFormProps = Readonly<{
  action: (state: ProposalActionState, formData: FormData) => Promise<ProposalActionState>;
  initialState: ProposalActionState;
  locale: AdminLocale;
}>;

type LoadFormCopy = Readonly<{
  assignmentContract: string;
  assignmentRequired: string;
  continueToAssignment: string;
  delivery: string;
  deliveryError: string;
  inputs: string;
  loadNumber: string;
  loadNumberError: string;
  mandatory: string;
  policy: string;
  pending: string;
  save: string;
  pickup: string;
  pickupError: string;
  quote: string;
  quoteError: string;
  title: string;
}>;

const copyByLocale: Readonly<Record<AdminLocale, LoadFormCopy>> = {
  en: {
    assignmentContract: "Assignment authority",
    assignmentRequired: "Proposal saved. Assign an active driver and vehicle before a route estimate can be requested.",
    continueToAssignment: "Open dispatch assignment",
    delivery: "Delivery stop",
    deliveryError: "Enter a delivery stop.",
    inputs: "Proposal inputs",
    loadNumber: "Load number",
    loadNumberError: "Enter a load number.",
    mandatory: "Mandatory dispatch assignment — drivers are notified. Drivers cannot accept or reject this load.",
    policy: "Only an owner, admin, or dispatcher can assign, reassign, or cancel a load. The server-owned workflow retains each authorized change in audit history and is responsible for the assignee-facing state.",
    pending: "Route estimate pending: no approved server provider is configured, so no miles have been invented.",
    pickup: "Pickup stop",
    pickupError: "Enter a pickup stop.",
    quote: "Quoted amount (USD)",
    quoteError: "Enter a quoted USD amount greater than zero.",
    save: "Save load proposal",
    title: "New load proposal",
  },
  es: {
    assignmentContract: "Autoridad de asignación",
    assignmentRequired: "Propuesta guardada. Asigna un conductor y vehículo activos antes de solicitar una estimación de ruta.",
    continueToAssignment: "Abrir asignación de despacho",
    delivery: "Parada de entrega",
    deliveryError: "Ingresa una parada de entrega.",
    inputs: "Datos de la propuesta",
    loadNumber: "Número de carga",
    loadNumberError: "Ingresa un número de carga.",
    mandatory: "Asignación obligatoria por despacho: se notifica al conductor. El conductor no puede aceptar ni rechazar esta carga.",
    policy: "Solo el propietario, administrador o despachador puede asignar, reasignar o cancelar una carga. El flujo controlado por el servidor conserva cada cambio autorizado en el historial de auditoría y es responsable del estado visible para el conductor asignado.",
    pending: "Estimación de ruta pendiente: no hay un proveedor de servidor aprobado configurado, así que no se inventaron millas.",
    pickup: "Parada de recogida",
    pickupError: "Ingresa una parada de recogida.",
    quote: "Monto cotizado (USD)",
    quoteError: "Ingresa un monto cotizado en USD mayor que cero.",
    save: "Guardar propuesta de carga",
    title: "Nueva propuesta de carga",
  },
};

const initialValues: ProposalValues = {
  delivery: "",
  loadNumber: "",
  pickup: "",
  quoteUsd: "",
};

function validate(field: ProposalField, value: string, copy: LoadFormCopy): string | null {
  if (field === "quoteUsd") {
    const numericValue = Number(value);
    return /^\d+(?:\.\d{1,2})?$/.test(value) && Number.isFinite(numericValue) && numericValue > 0
      ? null
      : copy.quoteError;
  }
  if (value.trim().length > 0) {
    return null;
  }
  if (field === "loadNumber") {
    return copy.loadNumberError;
  }
  return field === "pickup" ? copy.pickupError : copy.deliveryError;
}

export function LoadProposalForm({ action, initialState, locale }: LoadProposalFormProps) {
  const copy = copyByLocale[locale];
  const [values, setValues] = useState<ProposalValues>(initialValues);
  const [errors, setErrors] = useState<Partial<Record<ProposalField, string>>>({});
  const [proposalIntent, setProposalIntent] = useState<string | null>(null);
  const [state, formAction, isPending] = useActionState(action, initialState);

  useEffect(() => { setProposalIntent(crypto.randomUUID()); }, []);
  useEffect(() => {
    if (state.status === "success" && state.loadId) setProposalIntent(crypto.randomUUID());
  }, [state.loadId, state.status]);

  function updateValue(field: ProposalField, value: string) {
    setValues((current) => ({ ...current, [field]: value }));
  }

  function validateOnBlur(field: ProposalField) {
    const error = validate(field, values[field], copy);
    setErrors((current) => {
      if (error === null) {
        const { [field]: _removedError, ...remaining } = current;
        return remaining;
      }
      return { ...current, [field]: error };
    });
  }

  return (
    <section aria-labelledby="load-proposal-heading" style={{ display: "grid", gap: operationalTokens.spacing.section, maxWidth: "72rem" }}>
      <header>
        <p style={{ color: operationalTokens.color.mutedForeground, margin: 0 }}>{copy.inputs}</p>
        <h1 id="load-proposal-heading" style={{ marginBottom: operationalTokens.spacing.compact }}>{copy.title}</h1>
        {state.status === "pending" && <p role="status" style={noticeStyle}>{copy.pending}</p>}
        {state.routeStatus === "assignment_required" && <p role="status" style={noticeStyle}>{copy.assignmentRequired}</p>}
        {state.routeStatus === "assignment_required" && state.loadId && <a className="carrierflow-control" href={`/loads/${state.loadId}`}>{copy.continueToAssignment}</a>}
        {state.message && state.status !== "error" && state.status !== "forbidden" && <p role="status" style={noticeStyle}>{state.message}</p>}
        {(state.status === "error" || state.status === "forbidden") && <p role="alert" style={errorStyle}>{state.message}</p>}
      </header>

      <form action={formAction} aria-busy={isPending} aria-describedby={state.field ? `load-proposal-${state.field}-error` : undefined} noValidate>
      <input name="locale" type="hidden" value={locale} />
      <input name="intentKey" type="hidden" value={proposalIntent ?? ""} />
      <section aria-labelledby="proposal-inputs-heading" style={surfaceStyle}>
        <h2 id="proposal-inputs-heading" style={{ marginTop: 0 }}>{copy.inputs}</h2>
        <div style={fieldGridStyle}>
          <ProposalInput
            error={errors.loadNumber ?? (state.field === "loadNumber" ? state.message : undefined)}
            field="loadNumber"
            label={copy.loadNumber}
            onBlur={validateOnBlur}
            onChange={updateValue}
            value={values.loadNumber}
          />
          <ProposalInput
            error={errors.quoteUsd ?? (state.field === "quoteUsd" ? state.message : undefined)}
            field="quoteUsd"
            inputMode="decimal"
            label={copy.quote}
            onBlur={validateOnBlur}
            onChange={updateValue}
            value={values.quoteUsd}
          />
          <ProposalInput
            error={errors.pickup ?? (state.field === "pickup" ? state.message : undefined)}
            field="pickup"
            label={copy.pickup}
            onBlur={validateOnBlur}
            onChange={updateValue}
            value={values.pickup}
          />
          <ProposalInput
            error={errors.delivery ?? (state.field === "delivery" ? state.message : undefined)}
            field="delivery"
            label={copy.delivery}
            onBlur={validateOnBlur}
            onChange={updateValue}
            value={values.delivery}
          />
        </div>
        <button className="carrierflow-proposal-submit" disabled={isPending || proposalIntent === null} type="submit">
          {isPending ? (locale === "en" ? "Saving proposal…" : "Guardando propuesta…") : copy.save}
        </button>
      </section>
      </form>

      <MileageBreakdown locale={locale} routeEstimate={state.routeEstimate ?? null} />

      <section aria-labelledby="assignment-authority-heading" style={surfaceStyle}>
        <h2 id="assignment-authority-heading" style={{ marginTop: 0 }}>{copy.assignmentContract}</h2>
        <p style={{ fontWeight: 700, marginBottom: operationalTokens.spacing.standard }}>{copy.mandatory}</p>
        <p style={noticeStyle}>{copy.policy}</p>
      </section>
    </section>
  );
}

function ProposalInput({
  error,
  field,
  inputMode,
  label,
  onBlur,
  onChange,
  value,
}: Readonly<{
  error: string | undefined;
  field: ProposalField;
  inputMode?: "decimal";
  label: string;
  onBlur: (field: ProposalField) => void;
  onChange: (field: ProposalField, value: string) => void;
  value: string;
}>) {
  const id = `load-proposal-${field}`;
  const errorId = `${id}-error`;
  return (
    <div style={{ display: "grid", gap: operationalTokens.spacing.compact }}>
      <label htmlFor={id} style={{ fontWeight: 600 }}>{label}</label>
      <input
        aria-describedby={error ? errorId : undefined}
        aria-invalid={error ? "true" : undefined}
        className="carrierflow-proposal-input"
        id={id}
        inputMode={inputMode}
        name={field}
        onBlur={() => onBlur(field)}
        onChange={(event) => onChange(field, event.target.value)}
        type={field === "quoteUsd" ? "text" : "text"}
        value={value}
      />
      {error && <p id={errorId} role="alert" style={errorStyle}>{error}</p>}
    </div>
  );
}

const loadFormCss = `
  .carrierflow-proposal-input {
    background: var(--cf-color-surface);
    border: 1px solid var(--cf-color-border);
    border-radius: var(--cf-radius-control);
    color: var(--cf-color-foreground);
    font: inherit;
    min-block-size: var(--cf-control-target);
    padding-inline: var(--cf-space-standard);
  }
  .carrierflow-proposal-input:focus-visible {
    outline: var(--cf-focus-ring-width) solid var(--cf-color-ring);
    outline-offset: var(--cf-focus-offset);
  }
  .carrierflow-proposal-submit {
    background: var(--cf-color-primary);
    border: 1px solid var(--cf-color-primary);
    border-radius: var(--cf-radius-control);
    color: var(--cf-color-on-primary);
    font: inherit;
    font-weight: 700;
    min-block-size: var(--cf-control-target);
    margin-top: var(--cf-space-comfortable);
    padding-inline: var(--cf-space-comfortable);
  }
  .carrierflow-proposal-submit:focus-visible { outline: var(--cf-focus-ring-width) solid var(--cf-color-ring); outline-offset: var(--cf-focus-offset); }
  .carrierflow-proposal-submit:disabled { cursor: wait; opacity: .7; }
  @media (prefers-reduced-motion: reduce) {
    .carrierflow-proposal-input { transition: none; }
  }
`;

const surfaceStyle = {
  backgroundColor: operationalTokens.color.surface,
  border: `1px solid ${operationalTokens.color.border}`,
  borderRadius: operationalTokens.radius.surface,
  padding: operationalTokens.spacing.comfortable,
} as const;

const fieldGridStyle = {
  display: "grid",
  gap: operationalTokens.spacing.comfortable,
  gridTemplateColumns: "repeat(auto-fit, minmax(16rem, 1fr))",
} as const;

const noticeStyle = {
  color: operationalTokens.color.mutedForeground,
  margin: 0,
  maxWidth: "65ch",
} as const;

const errorStyle = {
  color: operationalTokens.color.destructive,
  margin: 0,
} as const;

export { loadFormCss };
