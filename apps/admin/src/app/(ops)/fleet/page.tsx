import { operationalTokens } from "../../../../../../packages/design-tokens/src/tokens";
import type { AdminLocale } from "../../layout";
import englishMessages from "../../../i18n/en.json";
import spanishMessages from "../../../i18n/es.json";

type FleetCopy = typeof englishMessages.fleet;

const fleetMessages: Record<AdminLocale, FleetCopy> = {
  en: englishMessages.fleet,
  es: spanishMessages.fleet,
};

export type FleetPageProps = Readonly<{
  /** Defaults to English until the authenticated locale preference is wired. */
  locale?: AdminLocale;
}>;

export function FleetContent({ locale }: Readonly<{ locale: AdminLocale }>) {
  const copy = fleetMessages[locale];

  return (
    <section aria-labelledby="fleet-heading">
      <h1 id="fleet-heading">{copy.heading}</h1>
      <section
        aria-labelledby="fleet-setup-heading"
        style={{
          backgroundColor: operationalTokens.color.surface,
          border: `1px solid ${operationalTokens.color.border}`,
          borderRadius: operationalTokens.radius.surface,
          marginBlockStart: operationalTokens.spacing.comfortable,
          maxWidth: "42rem",
          padding: operationalTokens.spacing.comfortable,
        }}
      >
        <h2 id="fleet-setup-heading">{copy.setupHeading}</h2>
        <p>{copy.emptyState}</p>
        <p>{copy.unavailableDescription}</p>
        <a className="carrierflow-control" href="/">
          {copy.returnToOverview}
        </a>
      </section>
    </section>
  );
}

export default function FleetPage({ locale = "en" }: FleetPageProps = {}) {
  return <FleetContent locale={locale} />;
}
