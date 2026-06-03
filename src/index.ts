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
  RELEASES: R2Bucket;
}

interface LicenseEntry {
  status: "active" | "revoked" | "trial" | "warned";
  tier: string;
  customer: string;
  expires: string | null;
  tables_enabled?: boolean; // Legacy — derived from tier if absent
  created: string;
  notes?: string;
  dek?: string; // Base64-encoded 32-byte AES key for content encryption
}

// Tiers that include custom tables access
const TABLES_TIERS = new Set(["forge", "partner", "internal"]);

// Release manifest stored in KV under "releases:latest"
interface ReleaseManifest {
  version: string;
  tarball_key: string;
  checksum_sha256: string;
  released_at: string;
  release_notes: string;
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

function parseSemver(v: string): [number, number, number] | null {
  const m = v.match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return null;
  return [parseInt(m[1]), parseInt(m[2]), parseInt(m[3])];
}

function semverGt(a: string, b: string): boolean | null {
  const pa = parseSemver(a);
  const pb = parseSemver(b);
  if (!pa || !pb) return null;
  for (let i = 0; i < 3; i++) {
    if (pa[i] > pb[i]) return true;
    if (pa[i] < pb[i]) return false;
  }
  return false; // equal
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

      // Derive tables_enabled from tier (support legacy KV flag)
      const tablesEnabled = TABLES_TIERS.has(license.tier) || Boolean(license.tables_enabled);

      // Build and sign JWT
      const now = Math.floor(Date.now() / 1000);
      const payload: JwtPayload = {
        license_key: key,
        tier: license.tier,
        customer: license.customer,
        expires: license.expires,
        tables_enabled: tablesEnabled,
        iat: now,
        exp: now + 86400, // 24 hours
      };

      const token = await signJWT(payload, env.LICENSE_JWT_SECRET);

      return jsonResponse({
        token,
        expires_in: 86400,
        tier: license.tier,
        customer: license.customer,
        dek: license.dek || null,
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
        tables_enabled: TABLES_TIERS.has(license.tier) || Boolean(license.tables_enabled),
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

    // GET /update/check
    if (path === "/update/check" && request.method === "GET") {
      const key = url.searchParams.get("license_key");
      const currentVersion = url.searchParams.get("current_version");

      if (!key || !currentVersion) {
        return jsonResponse(
          { error: "missing_params", message: "license_key and current_version required" },
          400,
        );
      }

      if (!parseSemver(currentVersion)) {
        return jsonResponse(
          { error: "invalid_version", message: "current_version must be semver (X.Y.Z)" },
          422,
        );
      }

      // Validate license
      const raw = await env.LICENSES.get(key);
      if (!raw) {
        return jsonResponse({ error: "invalid_key" }, 403);
      }
      const license = JSON.parse(raw) as LicenseEntry;
      if (license.status === "revoked") {
        return jsonResponse({ error: "license_revoked" }, 403);
      }
      if (license.expires && new Date(license.expires) < new Date()) {
        return jsonResponse({ error: "license_expired" }, 403);
      }

      // Get release manifest
      const manifestRaw = await env.LICENSES.get("releases:latest");
      if (!manifestRaw) {
        return jsonResponse({ error: "no_release", message: "No release published yet" }, 404);
      }
      const manifest = JSON.parse(manifestRaw) as ReleaseManifest;

      // Compare versions
      const comparison = semverGt(manifest.version, currentVersion);
      if (comparison === null) {
        return jsonResponse({ error: "invalid_manifest_version" }, 500);
      }
      if (!comparison) {
        return jsonResponse({
          update_available: false,
          latest_version: manifest.version,
        });
      }

      // Generate download URL — try signed R2 URL, fallback to proxy endpoint
      let downloadUrl: string;
      try {
        const signedUrl = await env.RELEASES.createSignedUrl(manifest.tarball_key, {
          expiresIn: 1800,
        });
        downloadUrl = signedUrl.toString();
      } catch {
        // Fallback: use Worker proxy endpoint
        downloadUrl = `${url.origin}/update/download?license_key=${encodeURIComponent(key)}`;
      }

      return jsonResponse({
        update_available: true,
        latest_version: manifest.version,
        download_url: downloadUrl,
        checksum_sha256: manifest.checksum_sha256,
        released_at: manifest.released_at,
        release_notes: manifest.release_notes,
      });
    }

    // GET /update/download — streams tarball from R2 (license-gated)
    if (path === "/update/download" && request.method === "GET") {
      const key = url.searchParams.get("license_key");
      if (!key) {
        return jsonResponse({ error: "missing_key" }, 400);
      }

      // Validate license
      const raw = await env.LICENSES.get(key);
      if (!raw) {
        return jsonResponse({ error: "invalid_key" }, 403);
      }
      const license = JSON.parse(raw) as LicenseEntry;
      if (license.status === "revoked") {
        return jsonResponse({ error: "license_revoked" }, 403);
      }
      if (license.expires && new Date(license.expires) < new Date()) {
        return jsonResponse({ error: "license_expired" }, 403);
      }

      // Get manifest to find tarball key
      const manifestRaw = await env.LICENSES.get("releases:latest");
      if (!manifestRaw) {
        return jsonResponse({ error: "no_release" }, 404);
      }
      const manifest = JSON.parse(manifestRaw) as ReleaseManifest;

      // Stream from R2
      const object = await env.RELEASES.get(manifest.tarball_key);
      if (!object) {
        return jsonResponse({ error: "tarball_not_found" }, 404);
      }

      return new Response(object.body, {
        headers: {
          "Content-Type": "application/gzip",
          "Content-Disposition": `attachment; filename="abi-${manifest.version}.tar.gz"`,
          "Content-Length": object.size.toString(),
          "X-ABI-Version": manifest.version,
          "X-ABI-Sha256": manifest.checksum_sha256,
        },
      });
    }

    // 404 for everything else
    return jsonResponse({ error: "not_found" }, 404);
  },
};
