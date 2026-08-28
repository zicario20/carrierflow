import { operationalTokens } from "../../../../../../../packages/design-tokens/src/tokens";
import type { AdminLocale } from "../../../../i18n/locale";
import { getRequestLocale } from "../../../../i18n/request-locale";

const loadingCopy: Readonly<Record<AdminLocale, string>> = {
  en: "Loading plan settings…",
  es: "Cargando configuración del plan…",
};

/** A localized route boundary, not an access-denied or billing claim. */
export function PlanSettingsLoadingContent({ locale }: Readonly<{ locale: AdminLocale }>) {
  return (
    <p
      aria-live="polite"
      role="status"
      style={{
        color: operationalTokens.color.mutedForeground,
        margin: 0,
      }}
    >
      {loadingCopy[locale]}
    </p>
  );
}

export default async function PlanSettingsLoading() {
  return <PlanSettingsLoadingContent locale={await getRequestLocale()} />;
}
