import "server-only";

import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";

import { createSupabaseServiceClient } from "../../../../../lib/supabase/service";
import { createFirebaseAdminPushSender } from "../../../../../server/notifications/firebase-admin-push-sender";
import {
  processOneDriverPushDelivery,
  type DriverPushDeliveryResult,
} from "../../../../../server/notifications/push-delivery-worker";
import { SupabaseDriverPushDeliveryStore } from "../../../../../server/notifications/supabase-push-delivery-store";
import {
  decryptPushToken,
  pushTokenEncryptionKeyFromEnvironment,
} from "../../../../../server/notifications/push-token-crypto";

const noStore = { "Cache-Control": "no-store" };
const workerSecretHeader = "x-carrierflow-push-worker-secret";

export async function internalPushDispatchResponse(
  request: Request,
  dependencies: Readonly<{
    workerSecret: string | undefined;
    run: () => Promise<DriverPushDeliveryResult>;
  }>,
): Promise<NextResponse> {
  const expected = dependencies.workerSecret?.trim();
  if (!expected) {
    return NextResponse.json({ error: "unavailable" }, { headers: noStore, status: 503 });
  }
  if (!constantTimeSecretEquals(request.headers.get(workerSecretHeader), expected)) {
    return NextResponse.json({ error: "unauthorized" }, { headers: noStore, status: 401 });
  }

  try {
    const result = await dependencies.run();
    return NextResponse.json({ status: result.status }, { headers: noStore });
  } catch {
    return NextResponse.json({ error: "unavailable" }, { headers: noStore, status: 503 });
  }
}

/**
 * This route is intentionally not scheduled here. E3-T5's private compose
 * job will invoke it with the operator secret. Missing key/FCM/service-role
 * configuration returns unavailable before any outbox claim is attempted.
 */
export async function POST(request: Request): Promise<NextResponse> {
  return internalPushDispatchResponse(request, {
    workerSecret: process.env.PUSH_WORKER_SECRET,
    run: runConfiguredPushWorker,
  });
}

async function runConfiguredPushWorker(): Promise<DriverPushDeliveryResult> {
  const encryptionKey = pushTokenEncryptionKeyFromEnvironment();
  const sender = createFirebaseAdminPushSender();
  if (!encryptionKey || !sender) return { status: "unavailable" };

  try {
    const store = new SupabaseDriverPushDeliveryStore(
      createSupabaseServiceClient() as never,
    );
    return processOneDriverPushDelivery({
      store,
      sender,
      workerId: randomUUID(),
      decryptor: {
        decrypt: (envelope) => decryptPushToken(envelope, encryptionKey),
      },
    });
  } catch {
    return { status: "unavailable" };
  }
}

function constantTimeSecretEquals(candidate: string | null, expected: string): boolean {
  if (candidate === null) return false;
  const candidateDigest = createHash("sha256").update(candidate, "utf8").digest();
  const expectedDigest = createHash("sha256").update(expected, "utf8").digest();
  return timingSafeEqual(candidateDigest, expectedDigest);
}
