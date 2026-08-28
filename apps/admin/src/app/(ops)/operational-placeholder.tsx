import { adminMessages } from "../../i18n/messages";
import type { AdminLocale } from "../../i18n/locale";

export type PlaceholderDestination = keyof (typeof adminMessages)["en"]["placeholder"];

export function OperationalPlaceholder({
  destination,
  locale,
}: Readonly<{
  destination: PlaceholderDestination;
  locale: AdminLocale;
}>) {
  const copy = adminMessages[locale].placeholder[destination];
  const headingId = `${destination}-placeholder-heading`;

  return (
    <section aria-labelledby={headingId}>
      <h1 id={headingId}>{copy.heading}</h1>
      <p>{copy.description}</p>
    </section>
  );
}
