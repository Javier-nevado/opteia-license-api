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
if [ -z "${HERMES_DIR:-}" ]; then
  # Auto-detect Hermes dir. System-mode deploys (all customers + Snowbytes) keep
  # Hermes at /opt/hermes-agent; multi-agent setups use per-user ~/.hermes/hermes-agent.
  # NB: under `sudo`, $HOME=/root, so defaulting to $HOME silently breaks system mode
  # (license grep fails -> exit 2). Prefer /opt/hermes-agent when its VERSION exists.
  if [ -f /opt/hermes-agent/VERSION ]; then
    HERMES_DIR="/opt/hermes-agent"
  else
    HERMES_DIR="$HOME/.hermes/hermes-agent"
  fi
fi
LICENSE_KEY="${OPTEIA_LICENSE_KEY:-}"
SERVICE_NAME="${ABI_SERVICE_NAME:-hermes-gateway}"

# Parse args
MODE=""
FORCE=false
SCHEDULE_TIME=""
EXPECT_VERSION=""   # --expect-version: refuse unless manifest matches (TOCTOU guard)
ROLLBACK_SNAPSHOT=""  # --rollback <path>: explicit manual restore

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) MODE="check"; shift ;;
    --apply) MODE="apply"; shift ;;
    --schedule) MODE="schedule"; SCHEDULE_TIME="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --expect-version) EXPECT_VERSION="$2"; shift 2 ;;
    --rollback) MODE="rollback"; ROLLBACK_SNAPSHOT="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "Usage: abi-update.sh --check-only | --apply [--force] [--expect-version X.Y.Z] | --schedule '<time>' | --rollback [<snapshot>]"
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
  response="$(curl -sf -G "$API_BASE/update/check" --data-urlencode "license_key=$LICENSE_KEY" --data-urlencode "current_version=$CURRENT_VERSION")"

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
  response="$(curl -sf -G "$API_BASE/update/check" --data-urlencode "license_key=$LICENSE_KEY" --data-urlencode "current_version=$check_version")"

  local update_available
  update_available="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('update_available',False))")"

  if [ "$update_available" != "True" ]; then
    echo "No update available and no download URL. Check API response."
    echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
    return 1
  fi

  local latest download_url checksum signature released_at
  latest="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)['latest_version'])")"
  download_url="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)['download_url'])")"
  checksum="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)['checksum_sha256'])")"
  signature="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('signature',''))")"
  released_at="$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('released_at',''))")"

  echo "Updating: $CURRENT_VERSION → $latest"

  # TOCTOU guard: if the caller consented to a specific version (the agent passed
  # --expect-version from the chat yes), refuse when the manifest now advertises
  # something different (e.g. it was re-published between check and apply).
  if [ -n "$EXPECT_VERSION" ] && [ "$latest" != "$EXPECT_VERSION" ]; then
    echo "FATAL: manifest version ($latest) != expected ($EXPECT_VERSION). Aborting (consent/version mismatch)." >&2
    write_status "$(cat <<EOF
{"update_available":false,"current_version":"$CURRENT_VERSION","latest_version":"$latest","release_notes":"","scheduled_at":null,"scheduled_by":"$(whoami)","status":"refused_version_mismatch","expected_version":"$EXPECT_VERSION"}
EOF
)"
    exit 1
  fi

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

  # Verify the minisign signature over the canonical manifest. This is the check
  # sha256 CANNOT provide: if an attacker compromises the Worker/KV/R2 and
  # re-publishes a backdoored tarball, they also rewrite checksum_sha256 — but
  # they cannot mint a valid minisign signature without the offline release key.
  # Fail-closed on a present-but-invalid signature; warn (fall back to sha256)
  # only for legacy unsigned releases during the rollout transition.
  local tarball_key="releases/abi-${latest}.tar.gz"
  printf '%s\n%s\n%s\n%s' "$latest" "$tarball_key" "$checksum" "$released_at" > "$tmpdir/manifest.txt"
  printf '%s' "$signature" | base64 -d > "$tmpdir/manifest.minisig" 2>/dev/null || true
  if [ -n "$signature" ]; then
    if ! command -v minisign >/dev/null 2>&1; then
      echo "minisign not found — installing (apt)..." >&2
      apt-get install -y -qq minisign >/dev/null 2>&1 || true
    fi
    if ! command -v minisign >/dev/null 2>&1; then
      echo "FATAL: minisign unavailable and a signature is present — cannot verify authenticity. Aborting." >&2
      rm -rf "$tmpdir"; exit 1
    fi
    local verified=false pk
    for pk in /opt/abi-tools/abi-release.pub; do
      [ -f "$pk" ] || continue
      if minisign -V -p "$pk" -m "$tmpdir/manifest.txt" -x "$tmpdir/manifest.minisig" -H -q >/dev/null 2>&1; then
        verified=true; break
      fi
    done
    if [ "$verified" != true ]; then
      echo "FATAL: minisign signature verification failed — refusing to apply an untrusted tarball." >&2
      write_status "$(cat <<EOF
{"update_available":false,"current_version":"$CURRENT_VERSION","latest_version":"$latest","release_notes":"","scheduled_at":null,"scheduled_by":"$(whoami)","status":"refused_bad_signature"}
EOF
)"
      rm -rf "$tmpdir"; exit 1
    fi
    echo "minisign signature verified."
  else
    echo "WARNING: release carries no minisign signature (legacy/unsigned) — authenticity rests on sha256 only." >&2
  fi

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

  # --- L4 (pre-stop): take the DB dump NOW. pg_dump needs the DB container UP,
  # so it MUST run before we stop services below. The code-dir tar follows later
  # (pre-extract); it does not need the DB. backup_dir/snap_ts declared here are
  # reused by the code-tar block.
  local backup_dir="/opt/abi-tools/backups" snap_ts snap_path=""
  snap_ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$backup_dir" 2>/dev/null || sudo mkdir -p "$backup_dir"
  for _c in abi-memory-db abi-db; do
    if docker exec "$_c" pg_dump -U abi_agent -d abi_memory >/dev/null 2>&1; then
      docker exec "$_c" pg_dump -U abi_agent -d abi_memory 2>/dev/null \
        | gzip > "$backup_dir/abi-memory-${snap_ts}.sql.gz" || rm -f "$backup_dir/abi-memory-${snap_ts}.sql.gz"
      break
    fi
  done

  # Stop services
  echo "Stopping services..."
  if [ "$svc_type" = "user" ]; then
    for u in $agent_users; do
      local uid
      uid="$(id -u "$u")"
      echo "  Stopping $SERVICE_NAME for $u..."
      sudo -u "$u" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
    done
  elif [ "$svc_type" = "system" ]; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
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

  # --- L4 (pre-extract): snapshot the code dir. The DB dump was taken above
  # (pre-stop, while the DB was up). Code-dir-only restore is only safe when no
  # DB migration advanced (see the health-gate below); the DB dump is the
  # safety-net for the case we deliberately do NOT auto-restore.
  snap_path="$backup_dir/hermes-agent-${CURRENT_VERSION}-${snap_ts}.tar.zst"
  echo "Snapshotting $HERMES_DIR -> $snap_path ..."
  tar --zstd -cf "$snap_path" \
      --exclude='__pycache__' --exclude='.venv' --exclude='.git' \
      --exclude='kanboard/data' --exclude='kanboard/plugins' \
      -C "$(dirname "$HERMES_DIR")" "$(basename "$HERMES_DIR")" 2>/dev/null || \
    { echo "WARNING: snapshot failed — proceeding WITHOUT a rollback safety net." >&2; snap_path=""; }
  # Retain only the last 3 snapshots/dumps. Guard the `ls`: with no match it
  # exits non-zero, which under `set -o pipefail` would abort the whole apply
  # before extract — wrap it so a missing dump never kills the update.
  { ls -1t "$backup_dir"/hermes-agent-*.tar.zst 2>/dev/null || true; } | tail -n +4 | xargs -r rm -f
  { ls -1t "$backup_dir"/abi-memory-*.sql.gz 2>/dev/null || true; } | tail -n +4 | xargs -r rm -f

  # Extract tarball over the code dir. Runs as root (via the wrapper/deferred
  # unit, or Major Tom's sudo), so extracted code files land root-owned.
  echo "Extracting update..."
  tar -xzf "$tarball" -C "$HERMES_DIR" --strip-components=1

  # Enforce the security invariant: the code DIR itself must be root-owned so a
  # compromised agent can't delete-and-replace the root-owned compose/Dockerfile
  # and inject code into the root `docker build`. .venv + __pycache__ are NOT in
  # the archive, so tar leaves them agent-owned (runtime keeps writing them).
  chown root:root "$HERMES_DIR"

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
      sudo -u "$u" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user start "$SERVICE_NAME" 2>/dev/null || true
    done
  elif [ "$svc_type" = "system" ]; then
    sudo systemctl start "$SERVICE_NAME" 2>/dev/null || true
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
    echo "HEALTH CHECK FAILED after update $CURRENT_VERSION -> $new_version." >&2
    # Default: alert-and-stop. A DB migration may have advanced during the new
    # code's first start; code-dir-only restore would then desync code vs DB and
    # make things worse. Only opt-in ABI_UNSAFE_CODE_RESTORE=1 (operator is sure
    # no migration ran) attempts a code-only restore, and even then gives up if
    # health still fails.
    if [ "${ABI_UNSAFE_CODE_RESTORE:-0}" = "1" ] && [ -n "$snap_path" ] && [ -f "$snap_path" ]; then
      echo "ABI_UNSAFE_CODE_RESTORE=1 — attempting code-only restore from $snap_path..." >&2
      do_rollback "$snap_path" || true
      if curl -sf http://localhost:8010/health >/dev/null 2>&1; then
        write_status "$(cat <<EOF
{"update_available":false,"current_version":"$CURRENT_VERSION","latest_version":"$CURRENT_VERSION","release_notes":"","scheduled_at":null,"scheduled_by":"$(whoami)","status":"rolled_back","failed_version":"$new_version","snapshot":"$snap_path"}
EOF
)"
        echo "Code-only rollback succeeded; back on $CURRENT_VERSION." >&2
        exit 0
      fi
    fi
    echo "Alert-and-stop: leaving the running state as-is for human review." >&2
    [ -n "$snap_path" ] && [ -f "$snap_path" ] && echo "  Code snapshot:    $snap_path" >&2
    ls "$backup_dir"/abi-memory-*.sql.gz >/dev/null 2>&1 && \
      echo "  DB dump (latest): $(ls -1t "$backup_dir"/abi-memory-*.sql.gz | head -1)" >&2
    echo "  Manual rollback:  /opt/abi-tools/abi-update.sh --rollback \"$snap_path\"" >&2
    write_status "$(cat <<EOF
{"update_available":false,"current_version":"$new_version","latest_version":"$new_version","release_notes":"","scheduled_at":null,"scheduled_by":"$(whoami)","status":"failed","previous_version":"$CURRENT_VERSION","snapshot":"$snap_path"}
EOF
)"
    exit 1
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
# ROLLBACK — explicit manual restore of a code-dir snapshot (system mode).
# NB: code-dir only. Does NOT revert a DB migration — only use when you are
# certain no schema advanced, otherwise restore the matching abi-memory dump.
# ---------------------------------------------------------------------------
do_rollback() {
  local snap="${1:-}"
  if [ -z "$snap" ] || [ ! -f "$snap" ]; then
    snap="$(ls -1t /opt/abi-tools/backups/hermes-agent-*.tar.zst 2>/dev/null | head -1)"
  fi
  if [ -z "$snap" ] || [ ! -f "$snap" ]; then
    echo "ERROR: no snapshot to roll back to in /opt/abi-tools/backups/." >&2
    exit 1
  fi
  echo "Rolling back from snapshot: $snap"
  if ! tar --zstd -tf "$snap" >/dev/null 2>&1; then
    echo "FATAL: snapshot $snap is unreadable — aborting rollback to avoid data loss." >&2
    exit 1
  fi
  cd "$HERMES_DIR" 2>/dev/null || true
  if sudo systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  fi
  if [ -f "$HERMES_DIR/docker-compose.abi-api.yml" ] && [ -f "$HERMES_DIR/docker.env" ]; then
    docker compose --env-file "$HERMES_DIR/docker.env" -f "$HERMES_DIR/docker-compose.abi-api.yml" stop 2>/dev/null || true
  fi
  local base parent
  base="$(basename "$HERMES_DIR")"
  parent="$(dirname "$HERMES_DIR")"
  ( cd "$parent" && rm -rf "$base" && mkdir -p "$base" && tar --zstd -xf "$snap" )
  if [ -f "$HERMES_DIR/docker-compose.abi-api.yml" ] && [ -f "$HERMES_DIR/docker.env" ]; then
    docker compose --env-file "$HERMES_DIR/docker.env" -f "$HERMES_DIR/docker-compose.abi-api.yml" up -d 2>&1 | tail -3
  fi
  sudo systemctl start "$SERVICE_NAME" 2>/dev/null || true
  echo "Waiting for health after rollback..."
  local r
  for r in $(seq 1 30); do
    if curl -sf http://localhost:8010/health >/dev/null 2>&1; then echo "Health OK after rollback."; break; fi
    sleep 2
  done
  write_status "$(cat <<EOF
{"update_available":false,"current_version":"$(cat "$HERMES_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')","latest_version":"","release_notes":"","scheduled_at":null,"scheduled_by":"$(whoami)","status":"rolled_back","snapshot":"$snap"}
EOF
)"
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
  rollback) do_rollback "$ROLLBACK_SNAPSHOT" ;;
esac
