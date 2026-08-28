import { operationalTokens } from "../../../../../../../packages/design-tokens/src/tokens";
import type { PilotEntitlement } from "../../../../server/billing/entitlement-service";
import type { AdminLocale } from "../../../../i18n/locale";
import { getRequestLocale } from "../../../../i18n/request-locale";
import { createSupabaseServerClient } from "../../../../lib/supabase/server";
import { getAuthenticatedDispatchContext } from "../../../../server/dispatch/dispatch-context";
import { getPilotEntitlement } from "../../../../server/billing/entitlement-service";
import type { MutationResult } from "../../../../server/result";

type PlanCopy = Readonly<{
  activeDrivers: string;
  capacity: string;
  contact: string;
  heading: string;
  noCheckout: string;
  ownerOnly: string;
  pilot: string;
  plan: string;
  plans: Readonly<Record<PilotEntitlement["planCode"], string>>;
  price: string;
  privacy: string;
  retry: string;
  trial: string;
  trialActive: string;
  trialExpired: string;
  unavailable: string;
}>;

const copyByLocale: Readonly<Record<AdminLocale, PlanCopy>> = {
  en: {
    activeDrivers: "Active drivers",
    capacity: "Driver capacity",
    contact: "Contact CarrierFlow to change a pilot plan.",
    heading: "Plan and privacy",
    noCheckout: "No payment or checkout is available in this private pilot.",
    ownerOnly: "Plan details are available only to the active company owner.",
    pilot: "Private pilot — billing is not enabled.",
    plan: "Pilot plan",
    plans: { growth: "Growth", scale: "Scale", starter: "Starter" },
    price: "Pilot price",
    privacy: "Location detail is retained for seven days. Evidence remains available for operational and legal audit; retention records keep counts only.",
    retry: "Retry plan settings",
    trial: "7-day trial",
    trialActive: "Trial active",
    trialExpired: "Trial ended",
    unavailable: "Plan details are temporarily unavailable. Try again or contact CarrierFlow support.",
  },
  es: {
    activeDrivers: "Conductores activos",
    capacity: "Capacidad de conductores",
    contact: "Contacta a CarrierFlow para cambiar un plan piloto.",
    heading: "Plan y privacidad",
    noCheckout: "No hay pago ni checkout disponible en este piloto privado.",
    ownerOnly: "Los detalles del plan solo están disponibles para el propietario activo de la empresa.",
    pilot: "Piloto privado: la facturación no está habilitada.",
    plan: "Plan piloto",
    plans: { growth: "Crecimiento", scale: "Escala", starter: "Inicial" },
    price: "Precio piloto",
    privacy: "El detalle de ubicación se conserva durante siete días. La evidencia permanece disponible para auditoría operativa y legal; los registros de retención solo conservan conteos.",
    retry: "Reintentar configuración del plan",
    trial: "Prueba de 7 días",
    trialActive: "Prueba activa",
    trialExpired: "Prueba finalizada",
    unavailable: "Los detalles del plan no están disponibles temporalmente. Inténtalo de nuevo o contacta al soporte de CarrierFlow.",
  },
};

export type PlanSettingsPageState =
  | Readonly<{ entitlement: PilotEntitlement; kind: "ready" }>
  | Readonly<{ kind: "owner_only" }>
  | Readonly<{ kind: "unavailable" }>;

/** Keeps a genuine authorization denial distinct from transient/missing data. */
export function resolvePlanSettingsPageState(
  result: MutationResult<PilotEntitlement> | null,
): PlanSettingsPageState {
  if (result === null) return { kind: "unavailable" };
  if (result.ok) return { entitlement: result.data, kind: "ready" };
  return result.error.code === "forbidden" ? { kind: "owner_only" } : { kind: "unavailable" };
}

function formatTrialDate(value: string, locale: AdminLocale): string {
  return new Intl.DateTimeFormat(locale === "en" ? "en-US" : "es-US", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

export function PlanSettingsContent({
  locale,
  state,
}: Readonly<{
  locale: AdminLocale;
  state: PlanSettingsPageState;
}>) {
  const copy = copyByLocale[locale];

  return (
    <section aria-labelledby="plan-settings-heading" style={{ display: "grid", gap: operationalTokens.spacing.section, maxWidth: "46rem" }}>
      <header>
        <h1 id="plan-settings-heading">{copy.heading}</h1>
        <p style={mutedTextStyle}>{copy.pilot}</p>
      </header>
      {state.kind === "owner_only" ? (
        <p role="status" style={surfaceStyle}>{copy.ownerOnly}</p>
      ) : state.kind === "unavailable" ? (
        <section aria-labelledby="plan-unavailable-heading" role="alert" style={surfaceStyle}>
          <h2 id="plan-unavailable-heading" style={{ marginTop: 0 }}>{copy.heading}</h2>
          <p style={mutedTextStyle}>{copy.unavailable}</p>
          <a className="carrierflow-control" href="/settings/plan">{copy.retry}</a>
        </section>
      ) : (
        <section aria-labelledby="pilot-entitlement-heading" style={surfaceStyle}>
          <h2 id="pilot-entitlement-heading" style={{ marginTop: 0 }}>{copy.plan}</h2>
          <dl style={detailsStyle}>
            <div>
              <dt style={termStyle}>{copy.plan}</dt>
              <dd style={valueStyle}>{copy.plans[state.entitlement.planCode]}</dd>
            </div>
            <div>
              <dt style={termStyle}>{copy.price}</dt>
              <dd style={valueStyle}>${state.entitlement.monthlyPriceUsd} USD / {locale === "en" ? "month" : "mes"}</dd>
            </div>
            <div>
              <dt style={termStyle}>{copy.capacity}</dt>
              <dd style={valueStyle}>{state.entitlement.driverCapacity}</dd>
            </div>
            <div>
              <dt style={termStyle}>{copy.activeDrivers}</dt>
              <dd style={valueStyle}>{state.entitlement.activeDriverCount} / {state.entitlement.driverCapacity}</dd>
            </div>
            <div>
              <dt style={termStyle}>{copy.trial}</dt>
              <dd style={valueStyle}>{state.entitlement.trialState === "active" ? copy.trialActive : copy.trialExpired} · {formatTrialDate(state.entitlement.trialEndsAt, locale)}</dd>
            </div>
          </dl>
          <p style={mutedTextStyle}>{copy.noCheckout}</p>
          <p style={mutedTextStyle}>{copy.contact}</p>
          <p style={mutedTextStyle}>{copy.privacy}</p>
        </section>
      )}
    </section>
  );
}

export default async function PlanSettingsPage() {
  const [locale, supabase] = await Promise.all([
    getRequestLocale(),
    createSupabaseServerClient(),
  ]);
  const context = await getAuthenticatedDispatchContext(supabase);
  const result = context === null
    ? null
    : await getPilotEntitlement({
      actorRole: context.role,
      client: supabase as never,
      companyId: context.companyId,
    });
  const state = resolvePlanSettingsPageState(result);

  return <PlanSettingsContent locale={locale} state={state} />;
}

const surfaceStyle = {
  backgroundColor: operationalTokens.color.surface,
  border: `1px solid ${operationalTokens.color.border}`,
  borderRadius: operationalTokens.radius.surface,
  margin: 0,
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
  gridTemplateColumns: "repeat(auto-fit, minmax(13rem, 1fr))",
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
