import { OperationalPlaceholder } from "../operational-placeholder";
import { getRequestLocale } from "../../../i18n/request-locale";

export default async function DriversPage() {
  return <OperationalPlaceholder destination="drivers" locale={await getRequestLocale()} />;
}
