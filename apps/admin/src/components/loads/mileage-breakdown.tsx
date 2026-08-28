import { operationalTokens } from "../../../../../packages/design-tokens/src/tokens";
import type { AdminLocale } from "../../i18n/locale";
import type { RouteEstimateRevision } from "../../server/routing/estimate-service";

type EstimateDisplay = Pick<
  RouteEstimateRevision,
  "emptyMiles" | "loadedMiles" | "quoteUsd" | "quoteUsdPerTotalMile" | "totalMiles"
>;

export type MileageBreakdownProps = Readonly<{
  locale: AdminLocale;
  routeEstimate: EstimateDisplay | null;
}>;

type MileageCopy = Readonly<{
  empty: string;
  loaded: string;
  pending: string;
  quote: string;
  rate: string;
  serverEstimate: string;
  total: string;
}>;

const copyByLocale: Readonly<Record<AdminLocale, MileageCopy>> = {
  en: {
    empty: "Empty / deadhead miles",
    loaded: "Loaded miles",
    pending: "Miles will appear only after the secure server workflow returns a route estimate.",
    quote: "Quoted amount",
    rate: "USD per total mile",
    serverEstimate: "This is a server-authoritative route estimate. Route calculations are not performed in your browser.",
    total: "Total estimated miles",
  },
  es: {
    empty: "Millas vacías / de aproximación",
    loaded: "Millas cargadas",
    pending: "Las millas aparecerán únicamente después de que el flujo seguro del servidor devuelva una estimación de ruta.",
    quote: "Monto cotizado",
    rate: "USD por milla total",
    serverEstimate: "Esta es una estimación de ruta autorizada por el servidor. Los cálculos de ruta no se realizan en el navegador.",
    total: "Millas totales estimadas",
  },
};

function formatDecimal(value: string, locale: AdminLocale): string {
  const [whole, fraction] = value.split(".");
  const separator = locale === "en" ? "," : ".";
  const decimal = locale === "en" ? "." : ",";
  const groupedWhole = (whole ?? "0").replace(/\B(?=(\d{3})+(?!\d))/g, separator);
  return fraction === undefined ? groupedWhole : `${groupedWhole}${decimal}${fraction}`;
}

function formatUsd(value: string, locale: AdminLocale): string {
  const amount = formatDecimal(value, locale);
  return locale === "en" ? `$${amount}` : `USD ${amount}`;
}

export function MileageBreakdown({ locale, routeEstimate }: MileageBreakdownProps) {
  const copy = copyByLocale[locale];

  return (
    <section aria-labelledby="mileage-breakdown-heading" style={sectionStyle}>
      <h2 id="mileage-breakdown-heading" style={{ marginTop: 0 }}>{copy.total}</h2>
      {routeEstimate === null ? (
        <p role="status" style={mutedTextStyle}>{copy.pending}</p>
      ) : (
        <>
          <p role="status" style={mutedTextStyle}>{copy.serverEstimate}</p>
          <dl style={breakdownStyle}>
            <MileageValue label={copy.empty} value={`${formatDecimal(routeEstimate.emptyMiles, locale)} mi`} />
            <MileageValue label={copy.loaded} value={`${formatDecimal(routeEstimate.loadedMiles, locale)} mi`} />
            <MileageValue label={copy.total} value={`${formatDecimal(routeEstimate.totalMiles, locale)} mi`} />
            <MileageValue label={copy.quote} value={formatUsd(routeEstimate.quoteUsd, locale)} />
            <MileageValue
              label={copy.rate}
              value={`${formatUsd(routeEstimate.quoteUsdPerTotalMile, locale)} / ${locale === "en" ? "total mi" : "milla total"}`}
            />
          </dl>
        </>
      )}
    </section>
  );
}

function MileageValue({ label, value }: Readonly<{ label: string; value: string }>) {
  return (
    <div style={{ display: "grid", gap: operationalTokens.spacing.compact }}>
      <dt style={{ color: operationalTokens.color.mutedForeground, fontWeight: 600 }}>{label}</dt>
      <dd style={{ fontSize: "1.125rem", fontVariantNumeric: "tabular-nums", fontWeight: 700, margin: 0 }}>{value}</dd>
    </div>
  );
}

const sectionStyle = {
  backgroundColor: operationalTokens.color.surface,
  border: `1px solid ${operationalTokens.color.border}`,
  borderRadius: operationalTokens.radius.surface,
  padding: operationalTokens.spacing.comfortable,
} as const;

const mutedTextStyle = {
  color: operationalTokens.color.mutedForeground,
  marginBottom: operationalTokens.spacing.comfortable,
  maxWidth: "65ch",
} as const;

const breakdownStyle = {
  display: "grid",
  gap: operationalTokens.spacing.comfortable,
  gridTemplateColumns: "repeat(auto-fit, minmax(11rem, 1fr))",
  margin: 0,
} as const;
