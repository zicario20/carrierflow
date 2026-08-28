import "server-only";

/**
 * Server-only FCM boundary. Production configuration and device registration
 * are intentionally out of scope: this accepts an already-authorized private
 * destination in a future worker and sends no business data.
 */
export type ServerOnlyFcmTransport = Readonly<{
  send: (payload: Readonly<{ notificationId: string }>) => Promise<void>;
}>;

export type DriverRefreshDispatchResult =
  | Readonly<{ status: "invalid_event" }>
  | Readonly<{ status: "not_configured" }>
  | Readonly<{ status: "sent" }>;

const notificationIdPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/**
 * Sends exactly one opaque outbox acknowledgement. This module neither loads
 * device tokens nor contacts FCM when no explicitly injected server transport
 * exists, so local/private-pilot deployments remain an honest no-op.
 */
export async function dispatchDriverRefreshHint({
  notificationId,
  transport,
}: Readonly<{
  notificationId: string;
  transport?: ServerOnlyFcmTransport;
}>): Promise<DriverRefreshDispatchResult> {
  if (!notificationIdPattern.test(notificationId)) {
    return { status: "invalid_event" };
  }
  if (!transport) return { status: "not_configured" };

  await transport.send({ notificationId });
  return { status: "sent" };
}
