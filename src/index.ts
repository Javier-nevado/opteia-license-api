/**
 * Opteia License API — Cloudflare Worker
 *
 * Endpoints:
 *   GET  /license/verify?key={key}&version={ver}  → signed JWT (24h TTL)
 *   GET  /license/health?key={key}                 → license status JSON
 *   POST /webhooks/invoiceninja                    → Invoice Ninja webhook
 */

interface Env {
  LICENSES: KVNamespace;
  LICENSE_JWT_SECRET: string;
  INVOICE_NINJA_WEBHOOK_SECRET?: string;
}

interface LicenseEntry {
  status: "active" | "revoked" | "trial" | "warned";
  tier: string;
  customer: string;
  expires: string | null;
  tables_enabled: boolean;
  created: string;
  notes?: string;
}

interface JwtPayload {
  license_key: string;
  tier: string;
  customer: string;
  expires: string | null;
  tables_enabled: boolean;
  iat: number;
  exp: number;
}

async function signJWT(payload: JwtPayload, secret: string): Promise<string> {
  const encoder = new TextEncoder();

  // JWT header
  const header = { alg: "HS256", typ: "JWT" };
  const headerB64 = btoa(JSON.stringify(header))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  const payloadB64 = btoa(JSON.stringify(payload))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  const data = encoder.encode(`${headerB64}.${payloadB64}`);
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, data);
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  return `${headerB64}.${payloadB64}.${sigB64}`;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    // GET /license/verify
    if (path === "/license/verify" && request.method === "GET") {
      const key = url.searchParams.get("key");
      const version = url.searchParams.get("version") || "unknown";

      if (!key) {
        return jsonResponse({ error: "missing_key" }, 400);
      }

      const raw = await env.LICENSES.get(key);
      if (!raw) {
        return jsonResponse({ error: "invalid_key" }, 403);
      }

      let license: LicenseEntry;
      try {
        license = JSON.parse(raw);
      } catch {
        return jsonResponse({ error: "invalid_license_data" }, 500);
      }

      // Check status
      if (license.status === "revoked") {
        return jsonResponse({ error: "license_revoked" }, 403);
      }

      // Check expiry
      if (license.expires) {
        const expiryDate = new Date(license.expires);
        if (expiryDate < new Date()) {
          return jsonResponse({ error: "license_expired" }, 403);
        }
      }

      // Build and sign JWT
      const now = Math.floor(Date.now() / 1000);
      const payload: JwtPayload = {
        license_key: key,
        tier: license.tier,
        customer: license.customer,
        expires: license.expires,
        tables_enabled: license.tables_enabled,
        iat: now,
        exp: now + 86400, // 24 hours
      };

      const token = await signJWT(payload, env.LICENSE_JWT_SECRET);

      return jsonResponse({
        token,
        expires_in: 86400,
        tier: license.tier,
        customer: license.customer,
      });
    }

    // GET /license/health
    if (path === "/license/health" && request.method === "GET") {
      const key = url.searchParams.get("key");
      if (!key) {
        return jsonResponse({ error: "missing_key" }, 400);
      }

      const raw = await env.LICENSES.get(key);
      if (!raw) {
        return jsonResponse({ error: "invalid_key" }, 404);
      }

      const license = JSON.parse(raw) as LicenseEntry;
      return jsonResponse({
        status: license.status,
        tier: license.tier,
        customer: license.customer,
        expires: license.expires,
        tables_enabled: license.tables_enabled,
      });
    }

    // POST /webhooks/invoiceninja
    if (path === "/webhooks/invoiceninja" && request.method === "POST") {
      // TODO: Implement Invoice Ninja webhook handling
      // 1. Verify HMAC signature using INVOICE_NINJA_WEBHOOK_SECRET
      // 2. Parse event type (invoice.paid, invoice.past_due, etc.)
      // 3. Map to license key via invoice metadata
      // 4. Update KV entry
      return jsonResponse({ status: "not_implemented" }, 501);
    }

    // 404 for everything else
    return jsonResponse({ error: "not_found" }, 404);
  },
};
