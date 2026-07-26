// supabase/functions/deliver-notifications/apns.test.ts
import { assertEquals, assertExists } from "https://deno.land/std@0.224.0/testing/asserts.ts";
import { base64url, buildProviderJWT, buildApnsPayload, importP8Key, shouldDeleteToken } from "./apns.ts";

// A real EC P-256 PKCS8 test key, generated solely for this test file (not a
// production credential) via: openssl ecparam -genkey -name prime256v1 -noout |
// openssl pkcs8 -topk8 -nocrypt
const TEST_P8 = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----`;

Deno.test("base64url has no padding or +/ characters", () => {
  const out = base64url(new TextEncoder().encode("hello???"));
  assertEquals(/[+/=]/.test(out), false);
});

Deno.test("buildProviderJWT produces a 3-part token with the right header/claims", async () => {
  const key = await importP8Key(TEST_P8);
  const jwt = await buildProviderJWT("ABC123KEYID", "TEAM123456", key);
  const parts = jwt.split(".");
  assertEquals(parts.length, 3);
  const header = JSON.parse(atob(parts[0].replace(/-/g, "+").replace(/_/g, "/")));
  assertEquals(header, { alg: "ES256", kid: "ABC123KEYID" });
  const claims = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
  assertEquals(claims.iss, "TEAM123456");
  assertExists(claims.iat);
  assertEquals(Math.abs(Date.now() / 1000 - claims.iat) < 5, true);
});

Deno.test("buildApnsPayload shapes the alert payload", () => {
  const payload = buildApnsPayload("早安!", "今天煮咖哩飯", "sous://plan/2026-07-27");
  assertEquals(payload, {
    aps: { alert: { title: "早安!", body: "今天煮咖哩飯" }, sound: "default" },
    deeplink: "sous://plan/2026-07-27",
  });
});

Deno.test("shouldDeleteToken always deletes on 410, regardless of reason", () => {
  assertEquals(shouldDeleteToken(410, undefined), true);
  assertEquals(shouldDeleteToken(410, "Unregistered"), true);
});

Deno.test("shouldDeleteToken deletes on 400 only when reason is BadDeviceToken", () => {
  assertEquals(shouldDeleteToken(400, "BadDeviceToken"), true);
});

Deno.test("shouldDeleteToken keeps the token on other 400 reasons", () => {
  assertEquals(shouldDeleteToken(400, "BadTopic"), false);
  assertEquals(shouldDeleteToken(400, "PayloadEmpty"), false);
  assertEquals(shouldDeleteToken(400, "BadExpirationDate"), false);
  assertEquals(shouldDeleteToken(400, undefined), false);
});

Deno.test("shouldDeleteToken keeps the token on unrelated status codes", () => {
  assertEquals(shouldDeleteToken(500, "InternalServerError"), false);
  assertEquals(shouldDeleteToken(403, "ExpiredProviderToken"), false);
});
