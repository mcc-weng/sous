// supabase/functions/deliver-notifications/apns.ts
// APNs provider-token (JWT) and payload construction. Kept free of any Supabase/DB
// dependency so it's unit-testable without a live database or real APNs credentials.
// Web Crypto's ECDSA sign() returns raw (r||s) format per spec — exactly what JWS
// ES256 expects, no DER conversion needed (unlike Node's crypto.sign default).

export function base64url(bytes: Uint8Array): string {
  let str = "";
  for (const b of bytes) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlJson(obj: unknown): string {
  return base64url(new TextEncoder().encode(JSON.stringify(obj)));
}

export async function importP8Key(p8: string): Promise<CryptoKey> {
  const pem = p8
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8", der.buffer, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
}

export async function buildProviderJWT(keyId: string, teamId: string,
                                       privateKey: CryptoKey): Promise<string> {
  const signingInput = `${base64urlJson({ alg: "ES256", kid: keyId })}.` +
    base64urlJson({ iss: teamId, iat: Math.floor(Date.now() / 1000) });
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, privateKey,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64url(new Uint8Array(sig))}`;
}

export function buildApnsPayload(title: string, body: string, deeplink: string | null) {
  return {
    aps: { alert: { title, body }, sound: "default" },
    ...(deeplink ? { deeplink } : {}),
  };
}

// APNs 410 (Unregistered) always means the token itself is dead. APNs 400 is shared by
// many unrelated errors (BadTopic, PayloadEmpty, BadExpirationDate, ...); only the
// "BadDeviceToken" reason means the token is invalid. Deleting on any 400 regardless of
// reason would silently wipe out an entire household's valid tokens the moment something
// else is misconfigured (e.g. a wrong APNS_BUNDLE_ID makes every send 400 BadTopic).
export function shouldDeleteToken(status: number, reason?: string): boolean {
  return status === 410 || (status === 400 && reason === "BadDeviceToken");
}

export async function sendPush(deviceToken: string, jwt: string, bundleId: string,
                               payload: unknown, sandbox: boolean): Promise<Response> {
  const host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  return fetch(`https://${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": bundleId,
      "apns-push-type": "alert",
    },
    body: JSON.stringify(payload),
  });
}
