#!/usr/bin/env bash
#
# One-script deploy for the MCP Gateway.
#
#   cp deploy/deploy.env.example deploy/deploy.env   # once: set DEPLOY_HOST
#   ./deploy/deploy.sh                 # build, migrate, swap, restart, verify
#   ./deploy/deploy.sh --provision     # also create the user, database, env file, unit, vhost
#   ./deploy/deploy.sh --rollback      # go back to the previous release
#
# The release is built ON the host: the host runs Linux x86_64 and developers run macOS ARM,
# and building where it runs avoids a cross-build. The host already has Elixir and Erlang
# because its sibling apps are Phoenix releases too.
#
# Safety properties, in order of how much they matter when the host is shared with other sites:
#   * nginx is validated with `nginx -t` before any reload, and an existing vhost is never
#     overwritten. A broken reload takes down every site on the host, not just this one.
#   * The release swap is a symlink rename, so it is atomic and instantly reversible.
#   * After restart the health endpoint is polled; if it never comes up the previous release
#     is restored automatically and the script exits non-zero.
#   * Secrets are generated on the host and never leave it. Nothing here prints them.
#   * It is idempotent: safe to run repeatedly, and --provision only fills in what is absent.
set -euo pipefail

# Host-specific settings live in deploy/deploy.env, which is gitignored so the server's
# address stays out of the repository. Environment variables still win over the file.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/deploy.env" ] && . "$SCRIPT_DIR/deploy.env"

HOST="${DEPLOY_HOST:-}"
DOMAIN="${DEPLOY_DOMAIN:-gateway.mcpharbor.dev}"
PORT="${DEPLOY_PORT:-4620}"
APP_USER=mcp_gateway
DB_NAME=mcp_gateway_prod
BASE=/opt/mcp-gateway
KEEP_RELEASES=5

PROVISION=0
ROLLBACK=0
SKIP_TESTS="${SKIP_TESTS:-0}"
for arg in "$@"; do
  case "$arg" in
    --provision) PROVISION=1 ;;
    --rollback)  ROLLBACK=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }

cd "$SCRIPT_DIR/.."
[ -f mix.exs ] || die "run this from the project (mix.exs not found)"
[ -n "$HOST" ] || die "DEPLOY_HOST is not set. Copy deploy/deploy.env.example to deploy/deploy.env and fill it in."

# ---------------------------------------------------------------- rollback
if [ "$ROLLBACK" = 1 ]; then
  say "Rolling back on $HOST"
  remote bash -euo pipefail -s <<'ROLLBACK_EOF'
    cd /opt/mcp-gateway/releases
    current=$(basename "$(readlink -f /opt/mcp-gateway/current)")
    previous=$(ls -1 | sort -r | awk -v c="$current" '$0 != c {print; exit}')
    [ -n "$previous" ] || { echo "no previous release to roll back to" >&2; exit 1; }
    ln -sfn "/opt/mcp-gateway/releases/$previous" /opt/mcp-gateway/current.tmp
    mv -Tf /opt/mcp-gateway/current.tmp /opt/mcp-gateway/current
    systemctl restart mcp-gateway
    echo "rolled back: $current -> $previous"
ROLLBACK_EOF
  exit 0
fi

# ---------------------------------------------------------------- preflight
say "Preflight"
remote 'echo ok >/dev/null' || die "cannot ssh to $HOST"
echo "  ssh to $HOST: ok"

if [ "$SKIP_TESTS" = 1 ]; then
  echo "  tests: skipped (SKIP_TESTS=1)"
else
  echo "  running tests locally..."
  mix test >/dev/null 2>&1 || die "tests failed; refusing to deploy. Re-run with --skip-tests to override."
  echo "  tests: pass"
fi

RELEASE="$(date -u +%Y%m%d%H%M%S)"
echo "  release: $RELEASE"

# ---------------------------------------------------------------- provision
if [ "$PROVISION" = 1 ]; then
  say "Provisioning (idempotent)"
  remote DOMAIN="$DOMAIN" PORT="$PORT" APP_USER="$APP_USER" DB_NAME="$DB_NAME" BASE="$BASE" \
    bash -euo pipefail -s <<'PROVISION_EOF'

    id "$APP_USER" >/dev/null 2>&1 || { useradd --system --create-home --home-dir /home/$APP_USER --shell /bin/bash "$APP_USER"; echo "  created user $APP_USER"; }
    mkdir -p "$BASE"/{releases,tmp}; chown -R "$APP_USER:$APP_USER" "$BASE"

    # uv/uvx: three catalog entries are Python upstreams and cannot launch without it.
    if ! command -v uvx >/dev/null 2>&1; then
      echo "  installing uv (needed by the Python upstreams)"
      curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh >/dev/null 2>&1
    fi
    command -v uvx >/dev/null 2>&1 && echo "  uvx: $(command -v uvx)" || echo "  uvx: STILL MISSING - python upstreams will fail closed"
    command -v npx >/dev/null 2>&1 && echo "  npx: $(command -v npx)" || echo "  npx: MISSING - node upstreams will fail closed"

    # Database role and database.
    if ! sudo -u postgres psql -Atc "select 1 from pg_roles where rolname='$APP_USER'" | grep -q 1; then
      DBPASS="$(openssl rand -hex 24)"
      sudo -u postgres psql -qc "create role $APP_USER login password '$DBPASS';" >/dev/null
      echo "$DBPASS" > /root/.mcp_gateway_dbpass; chmod 600 /root/.mcp_gateway_dbpass
      echo "  created postgres role $APP_USER"
    fi
    sudo -u postgres psql -Atc "select 1 from pg_database where datname='$DB_NAME'" | grep -q 1 || {
      sudo -u postgres createdb -O "$APP_USER" "$DB_NAME"; echo "  created database $DB_NAME"; }

    # Env file: created once with generated secrets, then hand-edited. Never overwritten.
    if [ ! -f /etc/mcp-gateway.env ]; then
      DBPASS="$(cat /root/.mcp_gateway_dbpass 2>/dev/null || echo CHANGEME)"
      cat > /etc/mcp-gateway.env <<ENVEOF
SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')
DATABASE_URL=ecto://$APP_USER:$DBPASS@127.0.0.1/$DB_NAME
PHX_HOST=$DOMAIN
PORT=$PORT
CANONICAL_BASE_URL=https://$DOMAIN
PHX_SERVER=true
UPSTREAM_IDLE_TIMEOUT_MS=180000
# REQUIRED by SEC and NWS terms - those entries fail closed until these are real.
GATEWAY_CONTACT_UA=
GATEWAY_CONTACT_EMAIL=
# Optional, raise upstream quotas.
NASA_API_KEY=
NCBI_API_KEY=
BLS_API_KEY=
OPENALEX_API_KEY=
ENVEOF
      chmod 640 /etc/mcp-gateway.env; chown root:$APP_USER /etc/mcp-gateway.env
      echo "  created /etc/mcp-gateway.env (contact details still blank)"
    else
      echo "  /etc/mcp-gateway.env exists, left alone"
    fi
PROVISION_EOF

  # systemd unit and nginx vhost are pushed from the repo so they stay version controlled.
  say "Installing systemd unit and nginx vhost"
  scp -q deploy/mcp-gateway.service "$HOST:/etc/systemd/system/mcp-gateway.service"
  sed -e "s/__DOMAIN__/$DOMAIN/g" -e "s/__PORT__/$PORT/g" deploy/nginx-vhost.conf > /tmp/vhost.$$
  scp -q /tmp/vhost.$$ "$HOST:/tmp/mcp-gateway.vhost"; rm -f /tmp/vhost.$$

  remote DOMAIN="$DOMAIN" bash -euo pipefail -s <<'NGINX_EOF'
    systemctl daemon-reload
    if [ -f "/etc/nginx/sites-available/$DOMAIN" ]; then
      echo "  vhost exists, left alone (certbot's HTTPS block lives there)"
      rm -f /tmp/mcp-gateway.vhost
    else
      mv /tmp/mcp-gateway.vhost "/etc/nginx/sites-available/$DOMAIN"
      ln -sfn "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
      # Validate BEFORE reloading: this host serves nine other sites and a bad config
      # would take all of them down.
      if nginx -t 2>/dev/null; then
        systemctl reload nginx; echo "  vhost installed, nginx reloaded"
      else
        rm -f "/etc/nginx/sites-enabled/$DOMAIN"
        echo "  nginx -t FAILED; vhost disabled again, nginx untouched" >&2
        nginx -t || true
        exit 1
      fi
    fi
NGINX_EOF
fi

# ---------------------------------------------------------------- ship source
say "Uploading source"
rsync -az --delete \
  --exclude '.git' --exclude '_build' --exclude 'deps' --exclude 'tmp' \
  --exclude '.elixir_ls' --exclude 'priv/static/cache_manifest.json' \
  -e 'ssh -o BatchMode=yes' ./ "$HOST:$BASE/tmp/src/"
echo "  uploaded to $BASE/tmp/src"

# ---------------------------------------------------------------- build + swap
say "Building release $RELEASE on the host"
remote RELEASE="$RELEASE" PORT="$PORT" bash -euo pipefail -s <<'BUILD_EOF'
  APP_USER=mcp_gateway; BASE=/opt/mcp-gateway
  chown -R "$APP_USER:$APP_USER" "$BASE/tmp/src"

  sudo -u "$APP_USER" -H bash -euo pipefail <<BUILDER
    export MIX_ENV=prod HOME=/home/$APP_USER
    cd $BASE/tmp/src
    mix local.hex --force --if-missing >/dev/null 2>&1 || mix local.hex --force >/dev/null
    mix local.rebar --force >/dev/null
    mix deps.get --only prod >/dev/null
    mix compile >/dev/null
    mix release --overwrite --path "$BASE/releases/$RELEASE" >/dev/null
BUILDER
  echo "  built $BASE/releases/$RELEASE"

  previous=""
  [ -L "$BASE/current" ] && previous="$(readlink -f "$BASE/current")"
  echo "$previous" > "$BASE/tmp/previous"

  # Atomic swap: rename over the symlink so there is no moment without a `current`.
  ln -sfn "$BASE/releases/$RELEASE" "$BASE/current.tmp"
  mv -Tf "$BASE/current.tmp" "$BASE/current"
  chown -h "$APP_USER:$APP_USER" "$BASE/current"
  echo "  current -> $RELEASE"

  systemctl enable mcp-gateway >/dev/null 2>&1 || true
  systemctl restart mcp-gateway
BUILD_EOF

# ---------------------------------------------------------------- verify
say "Verifying"
ok=0
for _ in $(seq 1 30); do
  if remote "curl -fsS -m 3 http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done

if [ "$ok" != 1 ]; then
  echo "  health check FAILED after 60s; rolling back" >&2
  remote bash -euo pipefail -s <<'FAIL_EOF'
    BASE=/opt/mcp-gateway
    previous="$(cat "$BASE/tmp/previous" 2>/dev/null || true)"
    if [ -n "$previous" ] && [ -d "$previous" ]; then
      ln -sfn "$previous" "$BASE/current.tmp"; mv -Tf "$BASE/current.tmp" "$BASE/current"
      systemctl restart mcp-gateway
      echo "  rolled back to $(basename "$previous")"
    else
      echo "  no previous release to roll back to (first deploy); service left stopped"
      systemctl stop mcp-gateway || true
    fi
FAIL_EOF
  echo
  remote 'journalctl -u mcp-gateway -n 40 --no-pager' 2>/dev/null | sed 's/^/    /' || true
  die "deploy failed and was rolled back"
fi
echo "  health: ok on 127.0.0.1:$PORT"

say "Catalog sync"
remote bash -euo pipefail -s <<'SYNC_EOF'
  set +e
  # `rpc` runs inside the already-running node. `eval` would boot a second copy of the app
  # and fight the live one for the port.
  /opt/mcp-gateway/current/bin/mcp_gateway rpc '
    case McpGateway.Catalog.Sync.sync_all([]) do
      {:ok, r} -> IO.puts("  imported=#{r.imported} updated=#{r.updated} delisted=#{r.delisted} skipped=#{r.skipped} failed=#{r.failed}")
      {:error, e} -> IO.puts("  catalog sync error: #{inspect(e)}")
    end' 2>&1 | tail -22 | sed 's/^/  /'
  exit 0
SYNC_EOF

say "Pruning old releases (keeping $KEEP_RELEASES)"
remote KEEP="$KEEP_RELEASES" bash -euo pipefail -s <<'PRUNE_EOF'
  cd /opt/mcp-gateway/releases
  keep_target="$(basename "$(readlink -f /opt/mcp-gateway/current)")"
  ls -1 | sort -r | tail -n +$((KEEP+1)) | while read -r old; do
    [ "$old" = "$keep_target" ] && continue
    rm -rf -- "$old" && echo "  removed $old"
  done
  rm -rf /opt/mcp-gateway/tmp/src
PRUNE_EOF

say "Deployed $RELEASE"
echo "  internal : http://127.0.0.1:$PORT/health"
echo "  public   : https://$DOMAIN/health"
if ! curl -fsS -m 8 "https://$DOMAIN/health" >/dev/null 2>&1; then
  cat <<TLS

  HTTPS is not answering yet. If this is the first deploy, issue the certificate:

      ssh "$HOST" certbot --nginx -d $DOMAIN

  certbot reuses the existing Let's Encrypt account on this host and edits only this
  vhost. Later deploys leave the vhost alone.
TLS
fi
