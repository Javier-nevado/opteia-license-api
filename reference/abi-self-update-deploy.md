# ABI Secure Self-Update — deploy & ops

The agent can trigger its own platform update through a single locked-down root
wrapper, verified against an offline signature, snapshotted, and applied on
explicit user consent. This doc covers the one-time setup and per-VM install.

> See `scripts/abi-update.sh`, `scripts/abi-update-trigger`, `scripts/abi-install-selfupdate.sh`,
> `scripts/release-upload.sh`, `scripts/abi-minisign-sign.py`, and the
> `skills/core/self-update` skill in the abi-skills repo for the implementation.

## Architecture (5 layers)

1. **Privilege** — agent may run only `/opt/abi-tools/abi-update-trigger` as root
   (sudoers NOPASSWD, `env_reset` + `secure_path`, no `SETENV`). The wrapper
   whitelists its own args, pins `HERMES=/opt/hermes-agent`, and refuses if the
   code dir or updater is not root-owned read-only.
2. **Deferred exec** — `apply` enqueues a `systemd-run --on-active=30s` root unit
   and returns, so the gateway (the agent) isn't killed mid-turn.
3. **Authenticity** — `release-upload.sh` minisign-signs a canonical manifest
   (version + tarball_key + sha256 + released_at); `abi-update.sh` verifies it
   against the shipped pubkey before extracting. Defends against Worker/KV/R2
   compromise (the one threat sha256 alone can't cover).
4. **Safety net** — snapshot + best-effort DB dump before apply; health-gated
   **alert-and-stop** on failure (auto code-restore only via `ABI_UNSAFE_CODE_RESTORE=1`).
5. **Consent + audit** — the `core/self-update` skill presents version + notes and
   applies only on an explicit "yes", binding the apply to the consented version.
   Every action is appended to a hash-chained, append-only audit log.

## One-time: generate the release signing key (on the release host)

```sh
mkdir -p ~/.minisign && chmod 700 ~/.minisign
# Empty password is fine for unattended releases — the key is 0600 here and the
# real protection is that the secret NEVER leaves this host (not on VMs, not in
# the Worker/KV). Back the .key up OFFLINE.
MINISIGN_PASSPHRASE="" python3 scripts/abi-minisign-sign.py \
  minisign -G -p ~/.minisign/abi-release.pub -s ~/.minisign/abi-release.key
chmod 600 ~/.minisign/abi-release.key
```

`reference/abi-release.pub` in this repo is the **public** half (committed; safe
to publish). Keep `abi-release.key` OFF the repo (gitignored).

## Install on a VM (fresh deploy OR existing)

Stage the four artifacts onto the VM (these are NOT in the release tarball — the
updater can't update itself), then run the installer:

```sh
# from the opteia-license-api checkout:
scp scripts/abi-update.sh scripts/abi-update-trigger \
    scripts/abi-install-selfupdate.sh reference/abi-release.pub \
    <user>@<vm>:/tmp/abi-su/

ssh <user>@<vm>
sudo /tmp/abi-su/abi-install-selfupdate.sh --source /tmp/abi-su --user <service-user>
```

The installer: `apt install minisign`; drops wrapper + updater + pubkey to
`/opt/abi-tools` (`root:root`, `chattr +i` on wrapper/pubkey); renders
`/etc/sudoers.d/abi-update` for the service user; sets `chattr +a` on the audit
log; validates with `visudo -c`. Idempotent — safe to re-run.

## ⚠️ Required: the code dir must be root-owned

The wrapper refuses `apply` unless `/opt/hermes-agent` itself is `root:root`
(mode 755). If the agent user owns the dir, it can delete-and-replace the
root-owned `docker-compose.abi-api.yml`/`Dockerfile` and inject code into the
root `docker build`. The runtime does NOT need to own the code dir — only
`.venv` and `__pycache__` (agent-owned, not in the tarball). So once per VM:

```sh
sudo chown root:root /opt/hermes-agent      # dir only; .venv/__pycache__ stay agent-owned
```

`abi-update.sh` re-asserts `chown root:root "$HERMES_DIR"` after every apply.
Fresh deploys should do the same in `abi-bootstrap.sh` right after the initial
extract (a one-line addition; lives in the hermes-agent repo).



The wrapper is a **true** privilege boundary only if the service user is NOT in
the `docker` group and has no blanket NOPASSWD sudo (the docker socket grants
arbitrary root). The gateway is a Python process that talks to its DB over
localhost — it does **not** need docker at runtime; all `docker compose` work
already runs as root through the wrapper. So on customer VMs, prefer to **remove
the service user from the docker group**. On the operator's own VMs (e.g.
Snowbytes) where the user already has NOPASSWD sudo + docker, the wrapper is an
audit/consent/defense-in-depth layer rather than a hard boundary.

Per-VM posture is recorded in the relevant deployment memory.

## Verify (as the service user)

```sh
sudo -n /opt/abi-tools/abi-update-trigger check      # read-only, no disruption
lsattr /opt/abi-tools/abi-update-trigger              # should show 'i' (immutable)
lsattr /opt/abi-tools/abi-release.pub                 # 'i'
lsattr /opt/abi-tools/update-audit.log                # 'a' (append-only)
visudo -c                                             # clean
```

Negative checks (should refuse): a tampered signature, or a `--expect-version`
that doesn't match the manifest.

## Publishing a signed release

```sh
# token with R2:Edit + KV:Edit + Workers Scripts:Edit
export CLOUDFLARE_API_TOKEN=...
./scripts/release-upload.sh --version 3.1.6 --notes "..."
# worker must carry the `signature` field — redeploy if not yet updated:
#   cd <license-api> && npx wrangler deploy
```

`/update/check` then returns `signature`; `abi-update.sh` verifies it on apply.
