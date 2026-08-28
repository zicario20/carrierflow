import { LoadProposalForm, loadFormCss } from "../../../../components/loads/load-form";
import { getRequestLocale } from "../../../../i18n/request-locale";
import { createLoadProposalAction } from "./actions";
import { initialProposalActionState } from "./action-state";

export default async function NewLoadProposalPage() {
  const locale = await getRequestLocale();

  return (
    <>
      <style>{loadFormCss}</style>
      <LoadProposalForm action={createLoadProposalAction} initialState={initialProposalActionState} locale={locale} />
    </>
  );
}
