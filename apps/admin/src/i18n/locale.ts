export type AdminLocale = "en" | "es";

type LocaleCandidate = Readonly<{
  locale: AdminLocale;
  order: number;
  quality: number;
}>;

const maximumAcceptLanguageLength = 512;
const maximumLanguageRanges = 20;

function parseQuality(parameters: string[]): number {
  const qualityParameter = parameters.find((parameter) => parameter.trim().toLowerCase().startsWith("q="));

  if (!qualityParameter) {
    return 1;
  }

  const quality = Number.parseFloat(qualityParameter.trim().slice(2));
  return Number.isFinite(quality) && quality >= 0 && quality <= 1 ? quality : 0;
}

/**
 * Resolves the first supported, positively weighted language range from an
 * Accept-Language header. CarrierFlow initially supports English and Spanish.
 */
export function resolveAdminLocale(acceptLanguage: string | null | undefined): AdminLocale {
  if (typeof acceptLanguage !== "string" || acceptLanguage.length === 0) {
    return "en";
  }

  const candidates = acceptLanguage
    .slice(0, maximumAcceptLanguageLength)
    .split(",")
    .slice(0, maximumLanguageRanges)
    .map((languageRange, order): LocaleCandidate | undefined => {
      const [tag, ...parameters] = languageRange.trim().split(";");
      const primaryTag = (tag ?? "").trim().split("-", 1)[0]?.toLowerCase();

      if (primaryTag !== "en" && primaryTag !== "es") {
        return undefined;
      }

      return {
        locale: primaryTag,
        order,
        quality: parseQuality(parameters),
      };
    })
    .filter((candidate): candidate is LocaleCandidate => candidate !== undefined)
    .sort((left, right) => right.quality - left.quality || left.order - right.order);

  return candidates.find((candidate) => candidate.quality > 0)?.locale ?? "en";
}
