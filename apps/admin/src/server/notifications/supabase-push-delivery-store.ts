import "server-only";

import type {
  DriverPushDeliveryClaim,
  DriverPushDeliveryStore,
} from "./push-delivery-worker";

type PushRpcResult = Readonly<{ data: unknown; error: unknown | null }>;

/**
 * Narrow adapter for a server-created service-role client. It intentionally
 * accepts no tenant, driver, load, or caller scope: the database worker RPCs
 * derive all delivery authority and release a decrypted destination only to
 * that service-role connection.
 */
export type ServerOnlyPushRpcClient = Readonly<{
  rpc: (name: string, params: Record<string, unknown>) => Promise<PushRpcResult>;
}>;

export class SupabaseDriverPushDeliveryStore
  implements DriverPushDeliveryStore
{
  constructor(private readonly client: ServerOnlyPushRpcClient) {}

  async claimNext(workerId: string): Promise<DriverPushDeliveryClaim | null> {
    const result = await this.client.rpc("claim_pending_driver_push_delivery", {
      worker_id: workerId,
    });
    throwOnRpcError(result.error);
    if (result.data === null) return null;
    return parseClaim(result.data);
  }

  async complete(deliveryId: string, leaseToken: string): Promise<void> {
    await this.invokeLease("complete_driver_push_delivery", deliveryId, leaseToken);
  }

  async invalidateDevice(deliveryId: string, leaseToken: string): Promise<void> {
    await this.invokeLease("invalidate_driver_push_device", deliveryId, leaseToken);
  }

  async release(deliveryId: string, leaseToken: string): Promise<void> {
    await this.invokeLease("release_driver_push_delivery", deliveryId, leaseToken);
  }

  private async invokeLease(
    name:
      | "complete_driver_push_delivery"
      | "invalidate_driver_push_device"
      | "release_driver_push_delivery",
    deliveryId: string,
    leaseToken: string,
  ): Promise<void> {
    const result = await this.client.rpc(name, {
      delivery_id_value: deliveryId,
      lease_token_value: leaseToken,
    });
    throwOnRpcError(result.error);
  }
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function parseClaim(value: unknown): DriverPushDeliveryClaim {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid private push delivery claim");
  }
  const record = value as Record<string, unknown>;
  const deliveryId = record.deliveryId;
  const ciphertext = decodeBase64(record.ciphertext);
  const iv = decodeBase64(record.iv, 12);
  const authTag = decodeBase64(record.authTag, 16);
  const leaseToken = record.leaseToken;
  const notificationId = record.notificationId;
  if (
    typeof deliveryId !== "string" ||
    typeof leaseToken !== "string" ||
    typeof notificationId !== "string" ||
    !uuidPattern.test(deliveryId) ||
    !uuidPattern.test(leaseToken) ||
    !uuidPattern.test(notificationId) ||
    ciphertext === null ||
    iv === null ||
    authTag === null
  ) {
    throw new Error("invalid private push delivery claim");
  }
  return {
    deliveryId,
    encryptedToken: { ciphertext, iv, authTag },
    leaseToken,
    notificationId,
  };
}

function decodeBase64(value: unknown, exactLength?: number): Buffer | null {
  if (typeof value !== "string" || value.length === 0) return null;
  const buffer = Buffer.from(value, "base64");
  if (
    buffer.length === 0 ||
    (exactLength !== undefined && buffer.length !== exactLength) ||
    buffer.toString("base64").replace(/=+$/, "") !== value.replace(/=+$/, "")
  ) {
    return null;
  }
  return buffer;
}

function throwOnRpcError(error: unknown): void {
  if (error !== null) {
    // Do not include a provider token, a server error body, or a database GUC
    // in an exception that a caller could log. Operational monitoring can use
    // the static category without retaining private delivery material.
    throw new Error("private push delivery store unavailable");
  }
}
