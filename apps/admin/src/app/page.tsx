import { adminMessages } from "../i18n/messages";
import { getRequestLocale } from "../i18n/request-locale";

export default async function HomePage() {
  const locale = await getRequestLocale();
  const copy = adminMessages[locale].home;

  return (
    <section aria-labelledby="carrierflow-home-heading">
      <h1 id="carrierflow-home-heading">{copy.heading}</h1>
      <p>{copy.description}</p>
    </section>
  );
}
