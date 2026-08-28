import "server-only";

import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
} from "node:crypto";

export type EncryptedPushToken = Readonly<{
  ciphertext: Buffer;
  iv: Buffer;
  authTag: Buffer;
  tokenHash: Buffer;
}>;

const aes256KeyLength = 32;
const aesGcmIvLength = 12;
const aesGcmTagLength = 16;
const hexKeyPattern = /^[a-f0-9]{64}$/i;
const base64KeyPattern = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

/**
 * Reads the server-only AES-256-GCM key representation. Base64 and hex are
 * accepted solely for deployment-secret ergonomics; anything else fails
 * closed before a provider token can be registered or decrypted.
 */
export function parsePushTokenEncryptionKey(value: string): Buffer {
  const normalized = value.trim();
  const key = hexKeyPattern.test(normalized)
    ? Buffer.from(normalized, "hex")
    : base64KeyPattern.test(normalized)
      ? Buffer.from(normalized, "base64")
      : Buffer.alloc(0);
  if (key.length !== aes256KeyLength) {
    throw new Error("PUSH_TOKEN_ENCRYPTION_KEY must be a 32-byte base64 or hex value");
  }
  return key;
}

export function pushTokenEncryptionKeyFromEnvironment(
  environment: Readonly<Record<string, string | undefined>> = process.env,
): Buffer | null {
  const value = environment.PUSH_TOKEN_ENCRYPTION_KEY;
  if (!value) return null;
  try {
    return parsePushTokenEncryptionKey(value);
  } catch {
    return null;
  }
}

export function encryptPushToken(token: string, key: Buffer): EncryptedPushToken {
  if (key.length !== aes256KeyLength) {
    throw new Error("a 32-byte AES key is required");
  }
  const iv = randomBytes(aesGcmIvLength);
  const cipher = createCipheriv("aes-256-gcm", key, iv, { authTagLength: aesGcmTagLength });
  const ciphertext = Buffer.concat([cipher.update(token, "utf8"), cipher.final()]);
  return {
    ciphertext,
    iv,
    authTag: cipher.getAuthTag(),
    tokenHash: createHash("sha256").update(token, "utf8").digest(),
  };
}

export function decryptPushToken(
  envelope: Pick<EncryptedPushToken, "ciphertext" | "iv" | "authTag">,
  key: Buffer,
): string {
  if (
    key.length !== aes256KeyLength ||
    envelope.iv.length !== aesGcmIvLength ||
    envelope.authTag.length !== aesGcmTagLength ||
    envelope.ciphertext.length === 0
  ) {
    throw new Error("invalid encrypted push token envelope");
  }
  const decipher = createDecipheriv("aes-256-gcm", key, envelope.iv, {
    authTagLength: aesGcmTagLength,
  });
  decipher.setAuthTag(envelope.authTag);
  return Buffer.concat([decipher.update(envelope.ciphertext), decipher.final()]).toString("utf8");
}
