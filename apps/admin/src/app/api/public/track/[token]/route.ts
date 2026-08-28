import { NextResponse } from "next/server";

import { createSupabaseServerClient } from "../../../../../lib/supabase/server";
import {
  resolvePublicTracking,
  type PublicTrackingReadClient,
} from "../../../../../server/tracking/public-tracking-service";

export type { PublicTrackingReadClient } from "../../../../../server/tracking/public-tracking-service";

const privateResponseHeaders = { "Cache-Control": "no-store" };

function missingPublicTrackingResponse(): NextResponse {
  // Deliberately no body: malformed, unknown, expired, revoked, and unavailable
  // capabilities have one generic 404 path with no oracle or link metadata.
  return new NextResponse(null, { headers: privateResponseHeaders, status: 404 });
}

export async function publicTrackingGetResponse({
  client,
  now,
  token,
}: Readonly<{
  client: PublicTrackingReadClient;
  now?: Date;
  token: string;
}>): Promise<NextResponse> {
  try {
    const view = await resolvePublicTracking({ client, now, token });
    if (view === null) return missingPublicTrackingResponse();
    return NextResponse.json(view, { headers: privateResponseHeaders });
  } catch {
    return missingPublicTrackingResponse();
  }
}

export async function GET(
  _request: Request,
  context: Readonly<{ params: Promise<Readonly<{ token: string }>> }>,
): Promise<NextResponse> {
  const { token } = await context.params;
  const client = (await createSupabaseServerClient()) as never as PublicTrackingReadClient;
  return publicTrackingGetResponse({ client, token });
}
