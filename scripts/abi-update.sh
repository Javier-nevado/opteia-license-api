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
STATUS_FILE="${ABI_STATUS_FILE:-/opt/abi-tools/update-status.json}"
HERMES_DIR="${HERMES_DIR:-$HOME/.hermes/hermes-agent}"
LICENSE_KEY="${OPTEIA_LICENSE_KEY:-}"
SERVICE_NAME="${ABI_SERVICE_NAME:-hermes-gateway}"

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
  { echo "$json" | sudo tee "$STATUS_FILE" > /dev/null 2>/dev/null; } || \
  { echo "$json" > "$STATUS_FILE" 2>/dev/null; } || true
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

  # Read opt-in compose profiles (e.g. kanban) from docker.env -> "--profile <p>" flags
  local profile_flags=""
  if [ -f docker.env ]; then
    local profiles
    profiles="$(grep -E '^COMPOSE_PROFILES=' docker.env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr ',' ' ' || true)"
    for p in $profiles; do
      [ -n "$p" ] && profile_flags="$profile_flags --profile $p"
    done
  fi
  [ -n "$profile_flags" ] && echo "Compose profiles enabled:$profile_flags"

  # Pre-flight: pull camofox (~2.24GB) so a network failure ABORTS before we stop services
  echo "Pre-pulling service images (camofox)..."
  if ! docker compose --env-file docker.env -f docker-compose.abi-api.yml $profile_flags pull camofox 2>&1 | tail -3; then
    echo "FATAL: camofox image pull failed — aborting BEFORE stopping services (network issue?)." >&2
    exit 1
  fi

  # Detect agent users (for skills reconcile) — orthogonal to service type. Always
  # populated so standard skills land even in system-service mode.
  local agent_users=""
  for u in $(ls /home/ 2>/dev/null); do
    if id "$u" &>/dev/null && [ -d "/home/$u/.hermes" ]; then
      agent_users="$agent_users $u"
    fi
  done

  # Detect service manager: active system service => system mode (customers +
  # Snowbytes run system hermes-gateway); else multi-agent user-level (.19 runs a
  # per-user abi-agent). Override the name with ABI_SERVICE_NAME (e.g. abi-agent).
  local svc_type=""  # "user" or "system"
  if sudo systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    svc_type="system"
    echo "Detected system service: $SERVICE_NAME (agent users:$agent_users)"
  elif [ -n "$agent_users" ]; then
    svc_type="user"
    echo "Detected multi-agent (user-level) setup with users:$agent_users"
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
    # Stop ALL compose services (incl. profile services) so bind-mounts kanboard
    # holds are released before extract. Never 'down' (rule 15) — 'stop' keeps volumes.
    docker compose --env-file docker.env -f docker-compose.abi-api.yml $profile_flags stop 2>/dev/null || true
  fi

  # Kanboard's rw bind-mounts (data/, plugins/) are written by the container's
  # www-data, which maps to a *different* host uid (e.g. dhcpcd/uuidd). The agent
  # user can't overwrite them -> extract dies on "Cannot utime: Operation not
  # permitted". chown just those dirs to the agent user so the extract (run as the
  # agent user) can refresh the stock. The container runs as root and re-claims
  # write access on next start. NB: we do NOT sudo the whole tar — the runtime
  # writes __pycache__ into the code dir, so it must stay agent-owned.
  if [ -d "$HERMES_DIR/kanboard" ]; then
    sudo chown -R "$(id -u):$(id -g)" "$HERMES_DIR/kanboard/data" "$HERMES_DIR/kanboard/plugins" 2>/dev/null || true
  fi

  # Extract tarball (as the agent user — keeps the code dir agent-owned).
  echo "Extracting update..."
  tar -xzf "$tarball" -C "$HERMES_DIR" --strip-components=1

  # Reconcile skills shipped in the new tarball (shared MCP + per-agent standard)
  echo "Reconciling skills..."
  if [ -d "$HERMES_DIR/opteia-skills/shared" ]; then
    sudo mkdir -p /opt/abi-tools/skills
    if command -v rsync >/dev/null 2>&1; then
      sudo rsync -a --delete "$HERMES_DIR/opteia-skills/shared/" /opt/abi-tools/skills/
    else
      sudo cp -a "$HERMES_DIR/opteia-skills/shared/." /opt/abi-tools/skills/
    fi
    sudo chown -R root:abi-agents /opt/abi-tools/skills 2>/dev/null || sudo chown -R root:root /opt/abi-tools/skills
    sudo chmod -R g+rX /opt/abi-tools/skills
    echo "  shared MCP skills -> /opt/abi-tools/skills"
  fi
  if [ -n "$agent_users" ] && [ -d "$HERMES_DIR/opteia-skills/standard" ]; then
    for u in $agent_users; do
      sudo -u "$u" mkdir -p "/home/$u/.hermes/skills/opteia/standard"
      sudo cp -a "$HERMES_DIR/opteia-skills/standard/." "/home/$u/.hermes/skills/opteia/standard/"
      sudo chown -R "$u:$u" "/home/$u/.hermes/skills/opteia/standard"
    done
    echo "  standard skills -> per-agent ~/.hermes/skills/opteia/standard"
    # Materialize per-skill credentials.env from the VM master .env
    if [ -f "$HERMES_DIR/opteia-skills/scripts/abi_skill_sync_creds.py" ]; then
      for u in $agent_users; do
        sudo -u "$u" python3 "$HERMES_DIR/opteia-skills/scripts/abi_skill_sync_creds.py" 2>/dev/null || true
      done
    fi
  fi

  # Restart services
  echo "Restarting services..."
  if [ -f docker-compose.abi-api.yml ] && [ -f docker.env ]; then
    docker compose --env-file docker.env -f docker-compose.abi-api.yml $profile_flags up -d 2>&1 | tail -3
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
