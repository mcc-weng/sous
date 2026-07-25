// supabase/functions/deliver-notifications/index.ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildApnsPayload, buildProviderJWT, importP8Key, sendPush } from "./apns.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID")!;
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID")!;
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID")!;
const APNS_P8_KEY = Deno.env.get("APNS_P8_KEY")!;
// aps-environment is "development" (see ios/project.yml) until a TestFlight/App Store
// build ships — flip this env var, not the code, when that happens.
const APNS_SANDBOX = (Deno.env.get("APNS_USE_SANDBOX") ?? "true") === "true";

// JWTs are valid up to 1h per Apple's docs; refreshed at 55m to stay well inside that.
let cachedJWT: { token: string; expiresAt: number } | null = null;

async function getProviderJWT(): Promise<string> {
  if (cachedJWT && cachedJWT.expiresAt > Date.now()) return cachedJWT.token;
  const key = await importP8Key(APNS_P8_KEY);
  const token = await buildProviderJWT(APNS_KEY_ID, APNS_TEAM_ID, key);
  cachedJWT = { token, expiresAt: Date.now() + 55 * 60 * 1000 };
  return token;
}

Deno.serve(async () => {
  // Safety valve: a row stuck 'scheduled' more than 24h past send_at (function down,
  // key misconfigured) is force-failed here rather than retried forever.
  await supabase.from("notifications")
    .update({ status: "failed", error: "expired" })
    .eq("status", "scheduled")
    .lt("send_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString());

  const { data: due, error } = await supabase
    .from("notifications")
    .select("id, household_id, title, body, deeplink")
    .eq("status", "scheduled")
    .lte("send_at", new Date().toISOString());
  if (error) return new Response(JSON.stringify({ ok: false, error: error.message }), { status: 500 });

  const jwt = await getProviderJWT();
  let sent = 0, failed = 0;

  for (const n of due ?? []) {
    const { data: members } = await supabase
      .from("household_members").select("user_id").eq("household_id", n.household_id);
    const userIds = (members ?? []).map((m) => m.user_id);
    const { data: tokens } = userIds.length
      ? await supabase.from("device_tokens").select("token").in("user_id", userIds)
      : { data: [] };

    const payload = buildApnsPayload(n.title, n.body, n.deeplink);
    let anySucceeded = false;
    let lastError = "";
    for (const { token } of tokens ?? []) {
      const res = await sendPush(token, jwt, APNS_BUNDLE_ID, payload, APNS_SANDBOX);
      if (res.ok) {
        anySucceeded = true;
      } else {
        const body = await res.text();
        lastError = `${res.status}: ${body}`;
        if (res.status === 410 || res.status === 400) {
          await supabase.from("device_tokens").delete().eq("token", token);
        }
      }
    }

    if ((tokens ?? []).length === 0) {
      await supabase.from("notifications")
        .update({ status: "failed", error: "no device_tokens for household" })
        .eq("id", n.id);
      failed++;
    } else if (anySucceeded) {
      await supabase.from("notifications")
        .update({ status: "sent", sent_at: new Date().toISOString() })
        .eq("id", n.id);
      sent++;
    } else {
      await supabase.from("notifications")
        .update({ status: "failed", error: lastError })
        .eq("id", n.id);
      failed++;
    }
  }

  return new Response(JSON.stringify({ ok: true, sent, failed }), {
    headers: { "content-type": "application/json" },
  });
});
