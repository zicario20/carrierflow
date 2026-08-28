import { operationalTokens } from "../../../../../../packages/design-tokens/src/tokens";
import { adminMessages } from "../../../i18n/messages";
import type { AdminLocale } from "../../../i18n/locale";
import { getRequestLocale } from "../../../i18n/request-locale";

export function FleetContent({ locale }: Readonly<{ locale: AdminLocale }>) {
  const copy = adminMessages[locale].fleet;

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

export default async function FleetPage() {
  return <FleetContent locale={await getRequestLocale()} />;
}
