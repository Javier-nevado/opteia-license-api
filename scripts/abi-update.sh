#!/usr/bin/env bash
# abi-update.sh — Check, schedule, and apply ABI updates on customer VMs
#
# Usage:
#   abi-update.sh --check-only           # Check for updates, write status, exit
#   abi-update.sh --schedule "sun 02:00" # Schedule apply at a specific time
#   abi-update.sh --apply                # Apply update immediately
#   abi-update.sh --apply --force        # Apply even if same version
#
# Modes:
#   --check-only: Calls /update/check, writes /opt/abi-tools/update-status.json
#   --schedule:   Schedules --apply via systemd-run --on-calendar
#   --apply:      Downloads tarball, rebuilds Docker, restarts services
#
# Multi-agent safety:
#   The first agent (admin) is the only one that should use --schedule/--apply.
#   All agents can read /opt/abi-tools/update-status.json to notify their users.

set -euo pipefail

API_BASE="https://api.opteia.com"
STATUS_FILE="/opt/abi-tools/update-status.json"
HERMES_DIR="${HERMES_DIR:-$HOME/.hermes/hermes-agent}"
LICENSE_KEY="${OPTEIA_LICENSE_KEY:-}"
SERVICE_NAME="${ABI_SERVICE_NAME:-$SERVICE_NAME}"

# Parse args
MODE=""
FORCE=false
SCHEDULE_TIME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) MODE="check"; shift ;;
    --apply) MODE="apply"; shift ;;
    --schedule) MODE="schedule"; SCHEDULE_TIME="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "Usage: abi-update.sh --check-only | --apply [--force] | --schedule '<time>'"
  exit 1
fi

if [ -z "$LICENSE_KEY" ]; then
  # Try reading from docker.env
  LICENSE_KEY="$(grep OPTEIA_LICENSE_KEY "$HERMES_DIR/docker.env" 2>/dev/null | cut -d= -f2)"
fi
if [ -z "$LICENSE_KEY" ]; then
  echo "ERROR: OPTEIA_LICENSE_KEY not set. Export it or add to docker.env."
  exit 1
fi

CURRENT_VERSION="$(cat "$HERMES_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$CURRENT_VERSION" ]; then
  CURRENT_VERSION="0.0.0"
fi

ensure_status_dir() {
  sudo mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || true
}

write_status() {
  local json="$1"
  ensure_status_dir
  echo "$json" | sudo tee "$STATUS_FILE" > /dev/null 2>/dev/null || echo "$json" > "$STATUS_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# CHECK
# ---------------------------------------------------------------------------
check_for_update() {
  echo "Checking for updates (current: $CURRENT_VERSION)..."
  local response
  response="$(curl -sf "$API_BASE/update/check?license_key=$LICENSE_KEY&current_version=$CURRENT_VERSION")"

  local update_available
  update_available="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('update_available',False))" 2>/dev/null)"

  if [ "$update_available" = "True" ]; then
    local latest notes
    latest="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)['latest_version'])")"
    notes="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('release_notes',''))")"

    echo "Update available: $CURRENT_VERSION → $latest"
    echo "Notes: $notes"

    # Write status file for other agents to read
    write_status "$(cat <<EOF
{"update_available":true,"current_version":"$CURRENT_VERSION","latest_version":"$latest","release_notes":"$notes","scheduled_at":null,"scheduled_by":null,"status":"available"}
EOF
)"
    return 0
  else
    local latest
    latest="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('latest_version','$CURRENT_VERSION'))")"
    echo "No update available. Current: $CURRENT_VERSION, Latest: $latest"

    write_status "$(cat <<EOF
{"update_available":false,"current_version":"$CURRENT_VERSION","latest_version":"$latest","release_notes":"","scheduled_at":null,"scheduled_by":null,"status":"up_to_date"}
EOF
)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# APPLY
# ---------------------------------------------------------------------------
apply_update() {
  echo "Checking for updates..."
  local response
  # Use version 0.0.0 to always get download URL (needed for --force reinstall)
  local check_version="$CURRENT_VERSION"
  if [ "$FORCE" = true ]; then
    check_version="0.0.0"
  fi
  response="$(curl -sf "$API_BASE/update/check?license_key=$LICENSE_KEY&current_version=$check_version")"

  local update_available
  update_available="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('update_available',False))")"

  if [ "$update_available" != "True" ]; then
    echo "No update available and no download URL. Check API response."
    echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
    return 1
  fi

  local latest download_url checksum
  latest="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)['latest_version'])")"
  download_url="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)['download_url'])")"
  checksum="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)['checksum_sha256'])")"

  echo "Updating: $CURRENT_VERSION → $latest"

  # Write status
  write_status "$(cat <<EOF
{"update_available":true,"current_version":"$CURRENT_VERSION","latest_version":"$latest","release_notes":"","scheduled_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","scheduled_by":"$(whoami)","status":"applying"}
EOF
)"

  # Download
  local tmpdir
  tmpdir="$(mktemp -d)"
  local tarball="$tmpdir/abi-$latest.tar.gz"
  echo "Downloading..."
  curl -sfL -o "$tarball" "$download_url"

  # Verify checksum
  local actual_sha
  actual_sha="$(sha256sum "$tarball" | cut -d' ' -f1)"
  if [ "$actual_sha" != "$checksum" ]; then
    echo "FATAL: Checksum mismatch! Expected: $checksum, Got: $actual_sha"
    rm -rf "$tmpdir"
    exit 1
  fi
  echo "Checksum verified."

  # Pre-build Docker image (while services still running)
  echo "Pre-building ABI API Docker image..."
  cd "$HERMES_DIR"
  if [ -f docker-compose.abi-api.yml ] && [ -f docker.env ]; then
    docker compose --env-file docker.env -f docker-compose.abi-api.yml build 2>&1 | tail -3
  fi

  # Detect service manager and agent users
  # Multi-agent: each user runs their own abi-agent/hermes-gateway service
  local svc_type=""  # "user" or "system"
  local agent_users=""

  # Check for multi-agent setup (users with abi-agent services)
  for u in $(ls /home/ 2>/dev/null); do
    if id "$u" &>/dev/null && [ -d "/home/$u/.hermes" ]; then
      agent_users="$agent_users $u"
    fi
  done

  if [ -n "$agent_users" ]; then
    svc_type="user"
    echo "Detected multi-agent setup with users:$agent_users"
  elif sudo systemctl status $SERVICE_NAME &>/dev/null 2>&1; then
    svc_type="system"
  fi

  # Stop services
  echo "Stopping services..."
  if [ "$svc_type" = "user" ]; then
    for u in $agent_users; do
      local uid
      uid="$(id -u "$u")"
      echo "  Stopping $SERVICE_NAME for $u..."
      sudo -u "$u" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user stop $SERVICE_NAME 2>/dev/null || true
    done
  elif [ "$svc_type" = "system" ]; then
    sudo systemctl stop $SERVICE_NAME 2>/dev/null || true
  fi
  if [ -f docker-compose.abi-api.yml ] && [ -f docker.env ]; then
    docker compose --env-file docker.env -f docker-compose.abi-api.yml down abi-api 2>/dev/null || true
  fi

  # Extract tarball
  echo "Extracting update..."
  tar -xzf "$tarball" -C "$HERMES_DIR" --strip-components=1

  # Restart services
  echo "Restarting services..."
  if [ -f docker-compose.abi-api.yml ] && [ -f docker.env ]; then
    docker compose --env-file docker.env -f docker-compose.abi-api.yml up -d abi-api 2>&1 | tail -3
  fi
  if [ "$svc_type" = "user" ]; then
    for u in $agent_users; do
      local uid
      uid="$(id -u "$u")"
      echo "  Starting $SERVICE_NAME for $u..."
      sudo -u "$u" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user start $SERVICE_NAME 2>/dev/null || true
    done
  elif [ "$svc_type" = "system" ]; then
    sudo systemctl start $SERVICE_NAME 2>/dev/null || true
  fi

  # Health check
  echo "Waiting for health check..."
  local retries=0
  while [ $retries -lt 30 ]; do
    if curl -sf http://localhost:8010/health > /dev/null 2>&1; then
      echo "Health check passed."
      break
    fi
    retries=$((retries + 1))
    sleep 2
  done
  if [ $retries -eq 30 ]; then
    echo "WARNING: Health check did not pass within 60 seconds. Manual intervention may be needed."
  fi

  # Cleanup
  rm -rf "$tmpdir"

  # Final status
  local new_version
  new_version="$(cat "$HERMES_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
  echo "Update complete: $CURRENT_VERSION → $new_version"

  write_status "$(cat <<EOF
{"update_available":false,"current_version":"$new_version","latest_version":"$new_version","release_notes":"","scheduled_at":null,"scheduled_by":null,"status":"up_to_date"}
EOF
)"

  # Docker cleanup
  docker builder prune -af 2>/dev/null && docker image prune -af 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# SCHEDULE
# ---------------------------------------------------------------------------
schedule_update() {
  # First check if there's an update
  check_for_update || true

  local calendar_expr="$SCHEDULE_TIME"
  echo "Scheduling update for: $calendar_expr"

  # Write scheduled status
  local latest
  latest="$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('latest_version',''))" 2>/dev/null || echo "unknown")"
  write_status "$(cat <<EOF
{"update_available":true,"current_version":"$CURRENT_VERSION","latest_version":"$latest","release_notes":"","scheduled_at":"$calendar_expr","scheduled_by":"$(whoami)","status":"scheduled"}
EOF
)"

  # Schedule via systemd-run --on-calendar (requires systemd)
  # Or fall back to `at`
  if command -v systemd-run &>/dev/null; then
    systemd-run --user --on-calendar="$calendar_expr" -- "$(readlink -f "$0") --apply" 2>/dev/null || \
    sudo systemd-run --on-calendar="$calendar_expr" -- "$(readlink -f "$0") --apply"
    echo "Scheduled via systemd (on-calendar: $calendar_expr)"
  elif command -v at &>/dev/null; then
    echo "$(readlink -f "$0") --apply" | at "$calendar_expr" 2>/dev/null
    echo "Scheduled via at ($calendar_expr)"
  else
    echo "ERROR: Neither systemd-run nor 'at' available. Cannot schedule."
    exit 1
  fi
}

# Run selected mode
case "$MODE" in
  check) check_for_update ;;
  apply) apply_update ;;
  schedule) schedule_update ;;
esac
