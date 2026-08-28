import { OperationalPlaceholder } from "../operational-placeholder";
import { getRequestLocale } from "../../../i18n/request-locale";

export default async function VehiclesPage() {
  return <OperationalPlaceholder destination="vehicles" locale={await getRequestLocale()} />;
}
