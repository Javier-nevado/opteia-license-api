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
  "released_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "release_notes": "${NOTES:-Release $VERSION}"
}
EOF
  rm -rf "$TMPDIR"
  exit 0
fi

# Require a Cloudflare API token for real publishes (dry-run is exempt)
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN not set. Export it, or run with --dry-run." >&2
  exit 1
fi

# Upload to R2
echo "Uploading to R2..."
cd "$WORKER_DIR"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" npx wrangler r2 object put "$R2_BUCKET/$R2_KEY" --file "$TARBALL_PATH" --remote --content-type="application/gzip" 2>&1 | tail -3

# Update KV manifest
echo "Updating KV manifest..."
RELEASED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MANIFEST_JSON="$(cat <<EOF
{"version":"$VERSION","tarball_key":"$R2_KEY","checksum_sha256":"$SHA256","released_at":"$RELEASED_AT","release_notes":"${NOTES:-Release $VERSION}"}
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
