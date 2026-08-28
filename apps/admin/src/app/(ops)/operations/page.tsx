import { OperationalPlaceholder } from "../operational-placeholder";
import { getRequestLocale } from "../../../i18n/request-locale";

export default async function OperationsPage() {
  return <OperationalPlaceholder destination="operations" locale={await getRequestLocale()} />;
}
