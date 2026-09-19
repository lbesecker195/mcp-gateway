# Deploying the MCP Gateway

One script. It provisions on first run and deploys on every run.

First, point it at your host. This file is gitignored, so the server's address is never
published:

```bash
cp deploy/deploy.env.example deploy/deploy.env
```

Then:

```bash
./deploy/deploy.sh --provision
```

```bash
./deploy/deploy.sh
```

```bash
./deploy/deploy.sh --rollback
```

## What it does

1. Runs the test suite locally and refuses to deploy if it fails (`--skip-tests` to override).
2. Rsyncs the source to `/opt/mcp-gateway/tmp/src`.
3. Builds the release **on the host**. The host is Linux x86_64 and developers are on macOS
   ARM; building where it runs avoids a cross-build, and the host already has Elixir because
   its sibling apps are Phoenix releases too.
4. Runs migrations, then swaps `/opt/mcp-gateway/current` with an atomic symlink rename.
5. Restarts `mcp-gateway.service` and polls `/health` for 60 seconds.
6. **Rolls back automatically** if health never comes up, and prints the journal.
7. Syncs the catalog in the live node over `rpc`, then prunes to the last 5 releases.

## The host is shared

This gateway runs alongside other sites and databases on the same machine. The script is
built around not breaking them:

- nginx is validated with `nginx -t` **before** any reload, and the vhost is removed again if
  validation fails. A bad reload takes down every site on the box, not just this one.
- An existing vhost is never overwritten, because certbot's HTTPS block lives in that file.
- Only `mcp-gateway.service` is ever restarted.
- The database role and database are this app's own; no other database is touched.

## Memory

This service is unusual: it spawns a Node or Python subprocess per upstream MCP server, and
those children share the service's cgroup. Seventeen upstreams at roughly 100 MB each is the
worst case, so `MemoryMax` in the unit has to cover the BEAM *plus* its children — otherwise
systemd OOM-kills the whole gateway rather than one upstream.

If memory gets tight, lower `UPSTREAM_IDLE_TIMEOUT_MS` in `/etc/mcp-gateway.env` before
lowering `MemoryMax`. It trades cold-start latency for resident memory.

The host also needs `node`/`npx` and `uv`/`uvx`: 14 catalog entries launch through npx and 3
through uvx. `--provision` installs `uv` if it is missing. Without either runtime those
upstreams fail closed and simply serve no tools.

## First deploy: two manual steps

**TLS.** The script installs an HTTP-only vhost; certbot adds the HTTPS block:

```bash
ssh "$DEPLOY_HOST" certbot --nginx -d gateway.mcpharbor.dev
```

It reuses the Let's Encrypt account already on the host, so there is no new agreement to
accept. The script does not run this itself — accepting a third party's terms is yours to do.

**Contact details.** Edit `/etc/mcp-gateway.env` and fill in:

```
GATEWAY_CONTACT_UA=MCP Gateway (gateway.mcpharbor.dev, you@example.com)
GATEWAY_CONTACT_EMAIL=you@example.com
```

These are not cosmetic. SEC EDGAR and the National Weather Service both require a User-Agent
identifying the operator with working contact details, and Crossref and NCBI want a contact
email. Until they are set, those four catalog entries **fail closed** and serve no tools —
which is the correct behaviour, because calling those APIs anonymously would breach the terms
recorded in [`catalog/COMPLIANCE.md`](../catalog/COMPLIANCE.md). Optional keys
(`NASA_API_KEY`, `NCBI_API_KEY`, `BLS_API_KEY`, `OPENALEX_API_KEY`) raise quotas on three more.

Re-run `./deploy/deploy.sh` afterwards to pick them up.

## CI

`.github/workflows/ci.yml` runs on every push: unused deps, formatting, compile with
warnings-as-errors, the full suite against Postgres 16, and `mix registry.export --check` so a
catalog entry the official registry would reject fails the build. Elixir and OTP are pinned to
what production runs, so a release that builds in CI builds on the host.

`.github/workflows/deploy.yml` deploys `main` after CI passes on that same commit, or on
manual dispatch. It runs in the `production` GitHub Environment — add a required reviewer
there if you want a human approving each deploy.

Required secrets:

| Secret | What |
|---|---|
| `DEPLOY_SSH_KEY` | Private key for deploys. **Generate a dedicated key**, do not paste your personal one. |
| `DEPLOY_HOST_IP` | The server's address. |
| `DEPLOY_KNOWN_HOSTS` | Output of `ssh-keyscan -H <server>`. Without it the workflow falls back to trust-on-first-use and warns. |
| `DEPLOY_SSH_USER` | Optional, defaults to `root`. |

Make the dedicated key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/mcp_gateway_deploy -C "github-actions mcp-gateway" -N ""
```

Install the public half on the host, put the private half in `DEPLOY_SSH_KEY`, and keep it
separate from your personal key so it can be revoked on its own.

A tighter option worth considering: give CI a non-root user with a narrow sudoers entry
instead of root. The deploy needs `systemctl restart mcp-gateway`, `nginx -t`, `systemctl
reload nginx` and write access to `/opt/mcp-gateway` — much less than root.
