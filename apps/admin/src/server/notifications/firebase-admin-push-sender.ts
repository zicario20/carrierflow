import "server-only";

import { cert, getApps, initializeApp } from "firebase-admin/app";
import { getMessaging } from "firebase-admin/messaging";

import type { ServerOnlyDriverPushSender } from "./push-delivery-worker";

export type FirebaseMessagingPort = Readonly<{
  send: (message: Readonly<{
    token: string;
    data: Readonly<{ notificationId: string }>;
    notification: Readonly<{
      title: "CarrierFlow";
    }>;
  }>) => Promise<string>;
}>;

type FirebaseServiceAccount = Readonly<{
  project_id: string;
  client_email: string;
  private_key: string;
}>;

type ServerEnvironment = Readonly<Record<string, string | undefined>>;

/**
 * Sends a neutral CarrierFlow OS alert plus an opaque refresh UUID. The
 * caller is intentionally unable to supply body, location, price, cargo or
 * document data.
 */
export class FirebaseAdminPushSender implements ServerOnlyDriverPushSender {
  constructor(private readonly messaging: FirebaseMessagingPort) {}

  async send(
    destination: string,
    payload: Readonly<{ data: Readonly<{ notificationId: string }> }>,
  ): Promise<void> {
    await this.messaging.send({
      token: destination,
      data: payload.data,
      notification: {
        title: "CarrierFlow",
      },
    });
  }
}

/**
 * Returns no sender unless the server-only service account is complete and
 * valid JSON. No credentials are accepted through browser configuration and
 * no provider call occurs until the worker has an encrypted claim.
 */
export function createFirebaseAdminPushSender(
  environment: ServerEnvironment = process.env,
): FirebaseAdminPushSender | undefined {
  const account = parseFirebaseServiceAccount(environment.FCM_SERVICE_ACCOUNT_JSON);
  if (!account) return undefined;

  const existing = getApps().find((app) => app.name === "carrierflow-driver-push");
  const app = existing ?? initializeApp({
    credential: cert({
      projectId: account.project_id,
      clientEmail: account.client_email,
      privateKey: account.private_key,
    }),
  }, "carrierflow-driver-push");
  return new FirebaseAdminPushSender(getMessaging(app));
}

export function parseFirebaseServiceAccount(
  rawValue: string | undefined,
): FirebaseServiceAccount | null {
  if (!rawValue) return null;
  try {
    const parsed: unknown = JSON.parse(rawValue);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    const record = parsed as Record<string, unknown>;
    const project_id = record.project_id;
    const client_email = record.client_email;
    const private_key = record.private_key;
    if (
      typeof project_id !== "string" || !project_id.trim() ||
      typeof client_email !== "string" || !client_email.includes("@") ||
      typeof private_key !== "string" || !private_key.includes("BEGIN PRIVATE KEY")
    ) {
      return null;
    }
    return { project_id, client_email, private_key };
  } catch {
    return null;
  }
}
