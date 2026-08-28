import "server-only";

export type DriverPushDeliveryClaim = Readonly<{
  deliveryId: string;
  encryptedToken: EncryptedDriverPushToken;
  leaseToken: string;
  notificationId: string;
}>;

/** Encrypted-only envelope returned by the service-role database claim. */
export type EncryptedDriverPushToken = Readonly<{
  ciphertext: Buffer;
  iv: Buffer;
  authTag: Buffer;
}>;

/** The private key lives only in this injected server boundary. */
export type ServerOnlyDriverPushTokenDecryptor = Readonly<{
  decrypt: (encryptedToken: EncryptedDriverPushToken) => string;
}>;

/**
 * Private service-role store. The database claim is the only place a device
 * destination can be decrypted; admin UI code must never import this type.
 */
export type DriverPushDeliveryStore = Readonly<{
  claimNext: (workerId: string) => Promise<DriverPushDeliveryClaim | null>;
  complete: (deliveryId: string, leaseToken: string) => Promise<void>;
  invalidateDevice: (deliveryId: string, leaseToken: string) => Promise<void>;
  release: (deliveryId: string, leaseToken: string) => Promise<void>;
}>;

/**
 * Adapter boundary for a configured FCM implementation. The sender receives a
 * private provider token but is permitted to transmit only the opaque UUID
 * under the `notificationId` data key. It must not log either value.
 */
export type ServerOnlyDriverPushSender = Readonly<{
  send: (
    destination: string,
    payload: Readonly<{ data: Readonly<{ notificationId: string }> }>,
  ) => Promise<void>;
}>;

export type DriverPushDeliveryResult =
  | Readonly<{ status: "unavailable" }>
  | Readonly<{ status: "idle" }>
  | Readonly<{ status: "delivered" }>
  | Readonly<{ status: "invalidated" }>
  | Readonly<{ status: "retryable" }>;

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/**
 * Processes one delivery only when both a service-role store and an explicitly
 * configured sender are available. No implicit FCM configuration, credentials
 * or production network send exists in the private-pilot code path.
 */
export async function processOneDriverPushDelivery({
  store,
  sender,
  decryptor,
  workerId,
}: Readonly<{
  store?: DriverPushDeliveryStore;
  sender?: ServerOnlyDriverPushSender;
  decryptor?: ServerOnlyDriverPushTokenDecryptor;
  workerId: string;
}>): Promise<DriverPushDeliveryResult> {
  if (!store || !sender || !decryptor || !uuidPattern.test(workerId)) {
    return { status: "unavailable" };
  }

  const claim = await store.claimNext(workerId);
  if (!claim) return { status: "idle" };
  if (!isValidClaim(claim)) {
    await store.release(claim.deliveryId, claim.leaseToken);
    return { status: "retryable" };
  }

  try {
    const destination = decryptor.decrypt(claim.encryptedToken);
    if (destination.length < 20) throw new Error("invalid encrypted destination");
    await sender.send(destination, {
      data: { notificationId: claim.notificationId },
    });
    await store.complete(claim.deliveryId, claim.leaseToken);
    return { status: "delivered" };
  } catch (error) {
    if (isInvalidProviderToken(error)) {
      await store.invalidateDevice(claim.deliveryId, claim.leaseToken);
      return { status: "invalidated" };
    }
    await store.release(claim.deliveryId, claim.leaseToken);
    return { status: "retryable" };
  }
}

function isValidClaim(claim: DriverPushDeliveryClaim): boolean {
  return (
    uuidPattern.test(claim.deliveryId) &&
    uuidPattern.test(claim.leaseToken) &&
    uuidPattern.test(claim.notificationId) &&
    Buffer.isBuffer(claim.encryptedToken.ciphertext) &&
    claim.encryptedToken.ciphertext.length > 0 &&
    Buffer.isBuffer(claim.encryptedToken.iv) &&
    claim.encryptedToken.iv.length === 12 &&
    Buffer.isBuffer(claim.encryptedToken.authTag) &&
    claim.encryptedToken.authTag.length === 16
  );
}

function isInvalidProviderToken(error: unknown): boolean {
  if (!error || typeof error !== "object" || !("code" in error)) return false;
  const code = (error as Readonly<{ code?: unknown }>).code;
  return (
    code === "registration-token-not-registered" ||
    code === "invalid-registration-token" ||
    code === "messaging/registration-token-not-registered" ||
    code === "messaging/invalid-registration-token"
  );
}
