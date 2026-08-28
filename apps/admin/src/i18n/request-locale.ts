import { headers } from "next/headers";

import { resolveAdminLocale } from "./locale";

export async function getRequestLocale() {
  const requestHeaders = await headers();
  return resolveAdminLocale(requestHeaders.get("accept-language"));
}
