#!/usr/bin/env bash
# release-upload.sh — Build and upload ABI release tarball to R2
#
# Usage:
#   ./scripts/release-upload.sh [--version 3.1.0] [--notes "Release notes"]
#   ./scripts/release-upload.sh --dry-run
#
# Prerequisites:
#   - Node.js 22+ with wrangler
#   - CLOUDFLARE_API_TOKEN set or wrangler logged in

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Source repo (Javier-nevado/hermes-agent, abi/main). Override with HERMES_DIR env.
HERMES_DIR="${HERMES_DIR:-/home/jnevado/claude-workspace-Opteia/workspace/hermes-agent-work}"
# Canonical shared-MCP-skills repo, overlaid into the tarball at build time.
# Private — needs `gh auth setup-git` (credential helper) or a token in the git URL.
ABI_SKILLS_REPO="${ABI_SKILLS_REPO:-https://github.com/Javier-nevado/abi-skills.git}"
R2_BUCKET="opteia-abi-releases"
KV_BINDING="LICENSES"
MANIFEST_KEY="releases:latest"

# Defaults
DRY_RUN=false
VERSION=""
NOTES=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Determine version
if [ -z "$VERSION" ]; then
  VERSION="$(cat "$HERMES_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$VERSION" ]; then
    echo "ERROR: No VERSION file found at $HERMES_DIR/VERSION"
    exit 1
  fi
fi

# Validate semver
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: Version '$VERSION' is not valid semver (X.Y.Z)"
  exit 1
fi

TARBALL_NAME="abi-${VERSION}.tar.gz"
R2_KEY="releases/${TARBALL_NAME}"
TMPDIR="$(mktemp -d)"
TARBALL_PATH="${TMPDIR}/${TARBALL_NAME}"

echo "=== ABI Release Upload ==="
echo "Version:  $VERSION"
echo "Source:   $HERMES_DIR"
echo "Tarball:  $TARBALL_NAME"
echo ""

# Stage a clean release tree: committed hermes-agent + shared skills from abi-skills.
# `git archive` only ships committed content, so we stage on a throwaway branch in a
# temp CLONE of the working copy and archive THAT branch — origin of both repos stays
# untouched and the working copy's uncommitted state is never released.
STAGE_DIR="$(mktemp -d)"
cleanup_stage() { rm -rf "$STAGE_DIR"; }
trap cleanup_stage EXIT
echo "Staging release tree (hermes-agent + abi-skills/shared)..."
if ! git clone -q --depth 1 "file://$HERMES_DIR" "$STAGE_DIR/hermes-agent"; then
  echo "ERROR: could not clone hermes-agent from $HERMES_DIR" >&2
  exit 1
fi
if ! git clone -q --depth 1 "$ABI_SKILLS_REPO" "$STAGE_DIR/abi-skills"; then
  echo "ERROR: could not clone $ABI_SKILLS_REPO (private — run 'gh auth setup-git' or embed a token)." >&2
  exit 1
fi
mkdir -p "$STAGE_DIR/hermes-agent/opteia-skills/shared" "$STAGE_DIR/hermes-agent/opteia-skills/scripts"
cp -a "$STAGE_DIR/abi-skills/skills/." "$STAGE_DIR/hermes-agent/opteia-skills/shared/"
cp -a "$STAGE_DIR/abi-skills/scripts/." "$STAGE_DIR/hermes-agent/opteia-skills/scripts/" 2>/dev/null || true
(
  cd "$STAGE_DIR/hermes-agent" || exit 1
  git checkout -q -b "release-stage-$VERSION"
  git add -A opteia-skills
  git -c user.email=release@opteia -c user.name="ABI Release" commit -q -m "stage: bundle abi-skills shared skills for release $VERSION"
)

echo "Creating tarball..."
git -C "$STAGE_DIR/hermes-agent" archive --format=tar.gz --prefix="hermes-agent/" -o "$TARBALL_PATH" "release-stage-$VERSION"

TARBALL_SIZE="$(du -h "$TARBALL_PATH" | cut -f1)"
SHA256="$(sha256sum "$TARBALL_PATH" | cut -d' ' -f1)"
RELEASED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Size:     $TARBALL_SIZE"
echo "SHA256:   $SHA256"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would upload:"
  echo "  R2:  $R2_BUCKET/$R2_KEY"
  echo "  KV:  $MANIFEST_KEY"
  echo ""
  echo "Manifest JSON:"
  cat <<EOF
{
  "version": "$VERSION",
  "tarball_key": "$R2_KEY",
  "checksum_sha256": "$SHA256",
  "released_at": "$RELEASED_AT",
  "release_notes": "${NOTES:-Release $VERSION}",
  "signature": "<minisign signature computed at publish>"
}
EOF
  rm -rf "$TMPDIR"
  exit 0
fi

# Require a Cloudflare API token for real publishes (dry-run is exempt).
# Source persisted release creds (0600, OUTSIDE any repo) if present so a publish
# doesn't need a manual export. Write the file yourself in your editor — never
# paste a token into a transcript.
for _cred in "$HOME/.config/opteia/cf-release.env"; do
  [ -f "$_cred" ] && { set -a; . "$_cred"; set +a; }
done
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN not set (env or ~/.config/opteia/cf-release.env), or run with --dry-run." >&2
  exit 1
fi

# Upload to R2
echo "Uploading to R2..."
cd "$WORKER_DIR"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" npx wrangler r2 object put "$R2_BUCKET/$R2_KEY" --file "$TARBALL_PATH" --remote --content-type="application/gzip" 2>&1 | tail -3

# Sign the canonical manifest with the offline minisign release key. The secret
# key lives ONLY on the release host (0600, empty password for CI, backed up
# offline); the matching public key ships to VMs. An attacker who compromises
# the Worker/KV/R2 can rewrite the tarball AND checksum_sha256, but cannot forge
# this signature. Fail-closed: never publish an unsigned release.
MINISIGN_SECKEY="${MINISIGN_SECKEY:-$HOME/.minisign/abi-release.key}"
SIGNATURE=""
if ! command -v minisign >/dev/null 2>&1; then
  echo "ERROR: minisign not installed on the release host (apt install minisign)." >&2; exit 1
fi
[ -f "$MINISIGN_SECKEY" ] || {
  echo "ERROR: minisign secret key not found at $MINISIGN_SECKEY." >&2
  echo "       Generate: minisign -G -p abi-release.pub -s \"\$MINISIGN_SECKEY\" (empty password for CI)." >&2
  exit 1
}
echo "Signing release manifest (minisign, -H prehash)..."
printf '%s\n%s\n%s\n%s' "$VERSION" "$R2_KEY" "$SHA256" "$RELEASED_AT" > "$TMPDIR/manifest.txt"
# minisign reads its password from /dev/tty only; the pty helper feeds it from
# MINISIGN_PASSPHRASE_FILE (default ~/.minisign/abi-release.pw, 0600) so the
# release pipeline runs unattended. Empty passphrase => key has empty password.
MINISIGN_PASSPHRASE_FILE="${MINISIGN_PASSPHRASE_FILE:-$HOME/.minisign/abi-release.pw}" \
  python3 "$SCRIPT_DIR/abi-minisign-sign.py" \
  minisign -S -s "$MINISIGN_SECKEY" -m "$TMPDIR/manifest.txt" -x "$TMPDIR/manifest.minisig" -t "abi $VERSION" -H
SIGNATURE="$(base64 -w0 < "$TMPDIR/manifest.minisig")"

# Update KV manifest
echo "Updating KV manifest..."
MANIFEST_JSON="$(cat <<EOF
{"version":"$VERSION","tarball_key":"$R2_KEY","checksum_sha256":"$SHA256","released_at":"$RELEASED_AT","release_notes":"${NOTES:-Release $VERSION}","signature":"$SIGNATURE"}
EOF
)"
if ! CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" npx wrangler kv:key put "$MANIFEST_KEY" --binding "$KV_BINDING" "$MANIFEST_JSON" 2>&1 | tail -3; then
  echo "wrangler kv put failed, trying Cloudflare API fallback..."
  CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-56cdbfd9d1c26a5822103017e170e020}"
  KV_NS_ID="b88b0aed85fd4e199cee3d4c4558db3a"
  ENCODED_JSON="$(echo "$MANIFEST_JSON" | base64 -w0)"
  curl -sf -X PUT "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$KV_NS_ID/values/$MANIFEST_KEY" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$MANIFEST_JSON" | python3 -c "import json,sys; r=json.load(sys.stdin); print('KV API:', 'OK' if r.get('success') else r.get('errors'))" 2>/dev/null || echo "WARNING: KV manifest update failed"
fi

echo ""
echo "=== Release $VERSION published successfully ==="

# Cleanup
rm -rf "$TMPDIR"
