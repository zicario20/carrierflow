import englishMessages from "./en.json";
import spanishMessagesSource from "./es.json";
import type { AdminLocale } from "./locale";

export type AdminMessages = typeof englishMessages;

const spanishMessages: AdminMessages = spanishMessagesSource;

export const adminMessages: Record<AdminLocale, AdminMessages> = {
  en: englishMessages,
  es: spanishMessages,
};
