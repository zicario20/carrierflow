import "server-only";

import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

import { getSupabasePublicEnv } from "../../../../lib/env";
import { createSupabaseServiceClient } from "../../../../lib/supabase/service";
import {
  encryptPushToken,
  pushTokenEncryptionKeyFromEnvironment,
} from "../../../../server/notifications/push-token-crypto";
import { parseFirebaseServiceAccount } from "../../../../server/notifications/firebase-admin-push-sender";

const noStore = { "Cache-Control": "no-store" };
const tokenPattern = /^[A-Za-z0-9:_-]{20,4096}$/;
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

export type BearerUserVerifier = Readonly<{
  getUser: (accessToken: string) => Promise<Readonly<{ id: string }> | null>;
}>;

export type EncryptedPushDeviceWriter = Readonly<{
  register: (input: Readonly<{
    targetUserId: string;
    tokenHash: Buffer;
    ciphertext: Buffer;
    iv: Buffer;
    authTag: Buffer;
    platform: "android" | "ios";
  }>) => Promise<void>;
}>;

type ServiceRoleRpcClient = Readonly<{
  rpc: (name: string, params: Record<string, unknown>) => Promise<Readonly<{
    data: unknown;
    error: unknown | null;
  }>>;
}>;

class SupabaseBearerUserVerifier implements BearerUserVerifier {
  constructor(private readonly client: ReturnType<typeof createClient>) {}

  async getUser(accessToken: string): Promise<Readonly<{ id: string }> | null> {
    const { data, error } = await this.client.auth.getUser(accessToken);
    if (error || !data.user || !uuidPattern.test(data.user.id)) return null;
    return { id: data.user.id };
  }
}

class SupabaseEncryptedPushDeviceWriter implements EncryptedPushDeviceWriter {
  constructor(private readonly client: ServiceRoleRpcClient) {}

  async register(input: Readonly<{
    targetUserId: string;
    tokenHash: Buffer;
    ciphertext: Buffer;
    iv: Buffer;
    authTag: Buffer;
    platform: "android" | "ios";
  }>): Promise<void> {
    const result = await this.client.rpc("register_server_encrypted_driver_push_device", {
      target_user_id: input.targetUserId,
      token_hash_value: bytea(input.tokenHash),
      token_ciphertext_value: bytea(input.ciphertext),
      token_iv_value: bytea(input.iv),
      token_auth_tag_value: bytea(input.authTag),
      platform_value: input.platform,
    });
    if (result.error !== null) throw new Error("server push-device registration unavailable");
  }
}

export async function pushDeviceRegistrationResponse(
  request: Request,
  dependencies: Readonly<{
    verifier: BearerUserVerifier;
    writer: EncryptedPushDeviceWriter;
    encryptionKey: Buffer | null;
    deliveryConfigured: boolean;
  }>,
): Promise<NextResponse> {
  const accessToken = bearerToken(request.headers.get("authorization"));
  if (!accessToken) return unauthorizedResponse();

  let user: Readonly<{ id: string }> | null;
  try {
    user = await dependencies.verifier.getUser(accessToken);
  } catch {
    user = null;
  }
  if (!user) return unauthorizedResponse();

  const payload = await requestPayload(request);
  if (!payload) {
    return NextResponse.json({ error: "invalid_request" }, { headers: noStore, status: 400 });
  }
  if (!dependencies.encryptionKey || !dependencies.deliveryConfigured) {
    return NextResponse.json({ error: "unavailable" }, { headers: noStore, status: 503 });
  }

  try {
    const encrypted = encryptPushToken(payload.pushToken, dependencies.encryptionKey);
    await dependencies.writer.register({
      targetUserId: user.id,
      tokenHash: encrypted.tokenHash,
      ciphertext: encrypted.ciphertext,
      iv: encrypted.iv,
      authTag: encrypted.authTag,
      platform: payload.platform,
    });
    return NextResponse.json({ registered: true }, { headers: noStore });
  } catch {
    // Do not reflect a provider token, raw service-role error, or encryption
    // material in an HTTP response that a mobile caller could log.
    return NextResponse.json({ error: "unavailable" }, { headers: noStore, status: 503 });
  }
}

export async function POST(request: Request): Promise<NextResponse> {
  try {
    const { supabaseAnonKey, supabaseUrl } = getSupabasePublicEnv();
    const verifier = new SupabaseBearerUserVerifier(createClient(supabaseUrl, supabaseAnonKey, {
      auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
    }));
    const writer = new SupabaseEncryptedPushDeviceWriter(
      createSupabaseServiceClient() as unknown as ServiceRoleRpcClient,
    );
    return pushDeviceRegistrationResponse(request, {
      verifier,
      writer,
      encryptionKey: pushTokenEncryptionKeyFromEnvironment(),
      deliveryConfigured: isPushDeliveryRuntimeConfigured(),
    });
  } catch {
    return NextResponse.json({ error: "unavailable" }, { headers: noStore, status: 503 });
  }
}

/**
 * Device registration is not a delivery promise. Require the same FCM service
 * account and private worker secret that the dispatch path needs before the
 * mobile app can receive a successful registration acknowledgement.
 */
export function isPushDeliveryRuntimeConfigured(
  environment: Readonly<Record<string, string | undefined>> = process.env,
): boolean {
  return (
    parseFirebaseServiceAccount(environment.FCM_SERVICE_ACCOUNT_JSON) !== null &&
    Boolean(environment.PUSH_WORKER_SECRET?.trim())
  );
}

function bearerToken(value: string | null): string | null {
  if (!value) return null;
  const match = /^Bearer ([^\s]+)$/.exec(value);
  return match?.[1] ?? null;
}

async function requestPayload(
  request: Request,
): Promise<Readonly<{ pushToken: string; platform: "android" | "ios" }> | null> {
  try {
    const body: unknown = await request.json();
    if (!body || typeof body !== "object" || Array.isArray(body)) return null;
    const record = body as Record<string, unknown>;
    const pushToken = record.pushToken;
    const platform = record.platform;
    if (
      typeof pushToken !== "string" ||
      !tokenPattern.test(pushToken) ||
      (platform !== "android" && platform !== "ios")
    ) {
      return null;
    }
    return { pushToken, platform };
  } catch {
    return null;
  }
}

function unauthorizedResponse(): NextResponse {
  return NextResponse.json({ error: "unauthorized" }, { headers: noStore, status: 401 });
}

function bytea(value: Buffer): string {
  return `\\x${value.toString("hex")}`;
}
