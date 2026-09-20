# AGENT.md — MCP Gateway (Phoenix)

Instructions for AI coding agents working in this repo. Read it before you change anything. It is also the shortest accurate description of what we are building.

## What this is

Phoenix is a paid MCP gateway. It puts many free and freemium APIs, reached through other MCP servers, behind one MCP endpoint and one catalog, and bills **$0.0001 per tool call**.

- **Catalog**: follows the [MCP Registry API](https://github.com/modelcontextprotocol/registry/blob/main/docs/reference/api/generic-registry-api.md). Each server is described by a `server.json`.
- **Gateway**: one MCP endpoint (Streamable HTTP) that routes `tools/call` to the right upstream server and meters it.
- **Docs**: every tool is documented for agents through `llms.txt`, `server.json`, `agent.txt`, `skill.txt` and related files, generated from the catalog.

## Rules that don't bend

1. **Price.** One billable unit is one successful upstream tool call: $0.0001. Discovery (registry endpoints, `initialize`, `tools/list`, docs files) is free. Keep the price in one config value, not in handlers.
2. **No floats for money.** Store integer micro-USD (1 µUSD = $0.000001, so one call = 100 µUSD).
3. **Metering is idempotent and fails closed.** One ledger row per call ID, written in the same transaction as the balance check. If the balance can't cover the call, reject it (HTTP 402) before contacting the upstream.
4. **Compliance gate, default deny.** A server or tool is listed and routable only if its provider's terms allow us to proxy it *and* charge for access. If the terms forbid it, or we can't verify them, it stays out of the catalog. Check both the MCP server's software license and the underlying API's terms, because they are separate. Each entry carries a compliance record: `terms_url`, `checked_on`, `verdict` (`allowed` / `not_allowed` / `unknown`), evidence quotes, and notes (attribution, rate limits, key required). Only `allowed` entries ship. When a re-check flips a verdict, delist and stop routing in the same change. `unknown` is a real answer, not a soft yes.

   The barrier is rarely the data licence — it is the access terms on top of it. Watch for: terms requiring every end user to hold their own key (FRED, Semantic Scholar, OpenAQ); terms naming API resellers or sublicensing as forbidden (Nominatim, Wikimedia, GitHub); and free tiers licensed for non-commercial use only (CoinGecko, Alpha Vantage). Open content does not imply an open pipe: Wikipedia, Wikidata and Open Library all publish reusable content under terms that forbid this delivery model. Read [catalog/COMPLIANCE.md](catalog/COMPLIANCE.md) before proposing a new integration — it records every API already rejected and why.
5. **Nothing invented.** Every server, tool, price, limit and terms verdict comes from a source you actually fetched. Put its URL in the entry. If you couldn't run an upstream server, don't list it. "As many as possible" means as many *verified* as possible.
6. **Secrets.** No keys, tokens or upstream credentials in the repo, logs, docs or fixtures. Upstream keys come from the environment or a secret store. Gateway API keys are stored hashed.
7. **Outbound calls.** Upstream endpoints come only from the catalog, never from request input (SSRF).
8. **Free-tier quotas are a constraint.** Enforce per-upstream rate limits and timeouts so we stay inside each provider's terms.

## Registry compatibility

- Target the `/v0.1/` API: `GET /v0.1/servers`, `GET /v0.1/servers/{serverName}/versions` and `GET /v0.1/servers/{serverName}/versions/{version}` (`latest` is accepted as a version). Respond with `application/json`, use opaque cursor pagination (`cursor`, `limit`), and URL-encode names and versions in paths. List responses are `{ "servers": [...], "metadata": { "count", "nextCursor" } }`.
- Read endpoints only. We don't expose `publish`: entries enter the catalog through the compliance gate, not through a public API.
- Gateway-specific data (price, compliance verdict, upstream mapping) goes in `_meta` under a reverse-DNS key for a domain we own. Never add it as extra top-level `server.json` fields.
- The spec moves. Before touching anything registry-facing, re-read `docs/reference/api/generic-registry-api.md` and `docs/reference/server-json/generic-server-json.md` in [modelcontextprotocol/registry](https://github.com/modelcontextprotocol/registry), and update this section if the version changes.

## Documentation surface

Generated from the catalog so it can't drift from what is actually routable. Hand-written additions live in a separate overrides directory and are merged in. Never hand-edit generated output.

| File | Working definition |
|---|---|
| `llms.txt` | Markdown index for LLMs: what the gateway is, how to connect and pay, links to tool docs ([llms.txt convention](https://llmstxt.org/)). |
| `llms-full.txt` | The same with full tool docs inlined. |
| `server.json` | Registry-format description of the gateway and of each proxied server. |
| `agent.txt` | For autonomous agents: discover, authenticate, pay, call, and handle errors and limits. |
| `skill.txt` | Task recipes that chain tools ("find X, then do Y"), with expected cost per recipe. |
| `/` | The landing page: what an MCP gateway is, what this one costs, what is in it. The only HTML we serve, generated by `McpGateway.Landing` from the live catalog. |
| `sitemap.xml`, `robots.txt` | Generated too, so a delisted server leaves the sitemap at the same moment it stops being routable. |
| `/try` | How to add the gateway to each AI client, and what you say to it afterwards. Makes no calls of its own. Every snippet is verified against that client's own docs — the field names differ (`servers` vs `mcpServers`, `url` vs `serverUrl`, `type` vs `transport`) and a wrong one fails in a way that looks like our outage. |

The landing page is the gateway's front door: it is what the registry entry's `websiteUrl`
points at and what an HTTP 402 tells people to visit, so `/` must never 404. It leads with
"what is an MCP gateway" because that is the query people actually search; keywords have to
be terms that genuinely describe what we serve, and the price and server list are read from
the catalog so the page cannot advertise something that has been delisted.

`agent.txt` and `skill.txt` are our own conventions, not published standards. Write their format down in `docs/` before generating them, and keep them plain text and versioned.

Every tool page states: what it does, inputs and outputs, an example call, the per-call price, the upstream provider and its attribution requirement, and rate limits. A listed tool without docs, or docs for an unlisted tool, is a build failure. Docs derived from upstream metadata (tool names, schemas, descriptions) must respect that upstream's license and attribution terms.

## Module map

| Module | Does |
|---|---|
| `McpGateway.Settings` | Typed config access. Price, namespaces, timeouts — never read `Application.get_env` directly elsewhere. |
| `McpGateway.Billing` | Accounts, hashed API keys, and the append-only ledger. All amounts integer µUSD. |
| `McpGateway.Catalog` | Read side. **Every** query is filtered to compliance-allowed, non-stale, active servers. |
| `McpGateway.Catalog.Compliance` | The gate: `servable?/3`, `stale?/2`, `cutoff/1`. |
| `McpGateway.Catalog.Sync` | Write side. Catalog files → rows, enforcing the gate and probing upstreams for tools. |
| `McpGateway.RegistryJSON` | The one place `server.json` is rendered. Registry API and docs both go through it. |
| `McpGateway.Upstream` | Dispatches to `Upstream.Stdio` (subprocess) or `Upstream.HTTP` (Streamable HTTP). |
| `McpGateway.MCP.Protocol` | Wire constants, error codes, header encoding. Aliased as `P`. |
| `McpGateway.Gateway` | The metering pipeline: resolve → rate limit → charge → call → refund on failure. |
| `McpGateway.Docs` | Generates `llms.txt`, `agent.txt`, `skill.txt` and the per-tool pages from the catalog. |
| `McpGateway.RateLimiter` | Fixed-window ETS counters, per account and per upstream. |

Tool names are namespaced `<slug>__<upstream_name>`, restricted to `[A-Za-z0-9_-]` and at most 64 characters, because some clients reject anything else (for example `arxiv__arxiv_search`).

## Catalog entries

One reviewed JSON file per upstream in `catalog/servers/<slug>.json`, imported by `mix catalog.sync`. The compliance record in each file is the audit trail: it carries the terms URL, the date we checked, and the decisive clauses quoted with their source URLs.

```json
{
  "slug": "arxiv",
  "name": "dev.mcpharbor.gateway/arxiv",
  "version": "1.0.0",
  "title": "arXiv",
  "description": "Search arXiv e-print metadata and categories.",
  "upstream": {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "@cyanheads/arxiv-mcp-server@1.5.3"],
    "env": { "SOME_KEY": { "from_env": "SOME_KEY" } }
  },
  "rate_limit": { "requests": 20, "window_ms": 60000 },
  "exclude_tools": ["arxiv_read_paper"],
  "compliance": { "verdict": "allowed", "terms_url": "...", "checked_on": "2026-09-19", "evidence": [] }
}
```

- **Pin the version.** `@1.5.3`, never `@latest`: an unpinned upstream is code we have not reviewed.
- **`exclude_tools` is a compliance tool.** Where terms permit some endpoints but not others, drop the tools rather than the server. arXiv permits discovery but not serving e-print full text; PubMed article full text carries publisher copyright the metadata does not.
- **Secrets come from the environment.** `{"from_env": "VAR"}` resolves at launch and fails closed when unset. Never put a key in a catalog file.
- **Rate limits are per upstream and shared across all our users.** Set them from the provider's published quota, and remember our whole fleet looks like one client to them.

## Registry optimization

Being found is most of the business: an agent that never discovers a tool never pays for it.
The rules below come from probing the live registry, not from guessing.

**How discovery actually works.** The official registry at `registry.modelcontextprotocol.io`
does a case-insensitive **raw substring** match over `name`, `title` and `description` only.
It does **no ranking at all** — ranking is left to downstream aggregators (PulseMCP, Glama, the
GitHub MCP Registry, Smithery) that consume its data. So the goal is to be indexed there,
accurately and completely, and let the aggregators rank us.

**The searchable surface is tiny.** `description` is capped at **100 characters** and there is
no keywords field in the schema. That 100 characters is the single most valuable text in the
project.

**Spend it on phrases, not words.** Single words are saturated (`weather`, `npm`, `edgar` each
return 100+ servers); natural multi-word phrases are almost all uncontested. At the last
survey, `sec edgar`, `world bank`, `currency conversion`, `interest rates`, `preprints`,
`clinical trials` and `mcp gateway` each returned **zero** results. Because the match includes
the space, a description that reads naturally is also the one that ranks.

**Rules for writing an entry:**

- Every keyword must be true of a tool the server actually exposes. We are trying to be found
  by people we can help, not by everyone.
- Keep `title` a clean human name. Clients render it in their UI, and a stuffed title is what
  reads as spam and gets entries moderated.
- Put extra search terms in the entry's `keywords` array. They reach our own registry's search
  and the `publisher-provided` metadata that aggregators read — not the official top-level
  schema, which has no such field.
- `mix registry.export --check` fails the build if an entry would be rejected. Run it before
  proposing catalog changes; `test/mcp_gateway/registry_publish_test.exs` enforces the same
  limits against the real catalog files.

**Publishing.** `mix registry.export` writes publish-ready documents to `tmp/registry/`; a
human reviews them and runs `mcp-publisher`. Two constraints shape what we publish:

- **Namespace ownership.** Publishing under `dev.mcpharbor.gateway` requires proving control of
  `gateway.mcpharbor.dev` by DNS first.
- **We publish `remotes`, never `packages`.** The registry verifies that a publisher owns any
  package they reference, and we do not own the upstream npm and PyPI packages we route to.
  Each entry describes the endpoint *we* operate and credits the upstream server and its
  licence in metadata. Never list an upstream package as ours.

Anything published or shown to a third party uses `Settings.canonical_base_url/0`, never
`base_url/0` — otherwise a publish from a laptop advertises `http://localhost`.

## Free trial and the demo

New accounts get `trial_credit_micro_usd` once, granted by `Billing.grant_trial/1`. The
idempotency key is the account id, so "once per account" is a property of the ledger rather
than of the code that calls it — a retried signup or a double-clicked button lands on the
same row.

`POST /v1/signup` is **off unless `SIGNUP_ENABLED=true`**. An open endpoint that mints real
credit with no email, card or challenge can be farmed in a loop; the per-address limit raises
the cost but does not prevent it. The direct exposure is not cash — upstream APIs are free —
it is upstream quota and the throttling that paying users would feel. Turn it on with
verification, or with a trial small enough that farming it is not worth the effort.

`agent.txt` documents the signup call, which is what makes "read agent.txt and sign up" work
as a prompt. If you change how signup works, change that section too — the `/try` page leads
with that prompt, and an agent that reads stale instructions fails in a way the user will
read as our fault.

**Order what you put in front of people by upstream headroom.** `Catalog.list_servers_by_capacity/0`
sorts by requests per minute, and the demo examples are chosen the same way. A provider's rate
limit is a condition of the terms that let us proxy it at all, so the tightest ones —
arXiv at 20/min, BLS at 450/day, NASA at 15/min — must not be the first thing a visitor clicks.
The demo deliberately uses OpenAlex rather than arXiv: same search-the-literature appeal,
thirty times the headroom.

## Running upstreams in production

Most catalog entries are stdio servers launched with `npx` or `uvx`, which has consequences worth planning for:

- **First call pays for a download.** `npx -y <pkg>@<version>` fetches from the registry on a cold start, which is why `upstream_startup_timeout_ms` is generous. Pre-install the pinned versions into the image instead of downloading at request time.
- **One subprocess per upstream, per node.** Seventeen Node and Python servers resident at once is real memory. They stop after `upstream_idle_timeout_ms` and restart on the next call; the protocol is stateless, so nothing is lost.
- **The subprocess inherits nothing.** It is launched through `env -i` with only `PATH`, an isolated `HOME`, and the variables its catalog entry declares, so one upstream can never read another's key or the gateway's database URL. There is a test asserting this; keep it.
- **Rate limits are per node.** The limiter counts in local ETS, so running N nodes multiplies the effective limit against the provider. Divide the published quota by the node count when setting an entry's `rate_limit`.
- **The aggregate `/mcp` endpoint exposes every tool at once.** With the full catalog that is a large `tools/list`. Point clients at `/mcp/<slug>` when they only need one provider.

## Git and GitHub workflow

Applies to repos under `lbesecker195/`.

- **Identity**: commit as Logan Besecker <me@LoganBesecker.com>, never as Claude.
- **Issue first**: open a GitHub issue before starting work that will be its own commit. It lists the affected pages.
- **One branch per commit**: a new branch every time.
- **Size**: commits are at most 200 words.
- **Links** in commits, issues and PRs: always the home page, at most 5 links in total. Use full absolute URLs to the live site, never relative ones, because they must point at the website, not GitHub. Anchor text targets keywords for that page, varied from commit to commit so the same page isn't always linked with the same keyword. Link only our own sites, never competitors'. When a change integrates with another of our sites, link that too, for example the [MCP Registry](https://ai.mcpharbor.dev/).
- **License**: everything is Apache 2.0. Keep `LICENSE` at the repo root.
- **Wiki**: keep the repo wiki current with every user-visible change. Attribute only our own sites.
- **Outside `lbesecker195/`**: don't force links to our sites. Most of the time they won't fit naturally.

Commit, issue and PR format:

```
<what changed and why, ~75 words>

- <3-5 bullets if needed>

---

Pages affected:

- [<keyword anchor>](<full https URL>) -- <~10 words about the page, with several keywords>
```

## Working agreements

- Verify before claiming. Run the tests and build, and report failures verbatim.
- Make the smallest change that does the job, in the style of the surrounding code.
- Ask first before publishing anything public, moving real money, or contacting third parties (for example a provider about their terms).

## Commands

Postgres must be running. `PGUSER` defaults to `postgres`; on a Homebrew install it is usually your own username.

```bash
PGUSER=logan mix test
```

- `mix setup` — fetch dependencies, create and migrate the database.
- `PGUSER=logan mix test` — the suite. It spawns real subprocess upstreams from `test/support/fixtures/fake_upstream.exs`, so it never touches the network.
- `mix catalog.sync` — import `catalog/servers/*.json`, enforcing the compliance gate. `--offline` skips probing upstreams, `--slug <slug>` does one entry.
- `mix registry.export` — write publish-ready `server.json` files for the official MCP
  Registry into `tmp/registry/`, validating each first. `--check` validates without writing.
  It never publishes; see **Registry optimization**.
- `mix phx.server` — run the gateway on `localhost:4000`.
- `mix precommit` — compile with warnings as errors, check unused deps, format, test. Run before you finish.
- `./deploy/deploy.sh` — build on the host, migrate, swap the release symlink, restart, verify,
  and roll back automatically if health fails. `--provision` on first run, `--rollback` to undo.
  See [deploy/README.md](deploy/README.md); the host is shared with nine other sites.

Environment variables the catalog entries expect: `GATEWAY_CONTACT_UA` and `GATEWAY_CONTACT_EMAIL` (SEC, NWS, Crossref and NCBI all require identifying contact details), plus optional `NASA_API_KEY`, `NCBI_API_KEY`, `BLS_API_KEY` and `OPENALEX_API_KEY` for higher quotas. An entry whose `from_env` variable is unset fails closed rather than calling the provider anonymously.

## Decided (2026-09-19)

- **Stack**: Elixir and the Phoenix framework, with Postgres and Ecto. The app is `mcp_gateway`. "Phoenix" is the project's name and also its framework.
- **Payment rail**: prepaid credits. A card charge per call isn't viable at $0.0001, so users top up a balance and each call draws it down by 100 µUSD in an append-only ledger. Top-up providers plug in behind the billing context; the ledger is the source of truth.
- **Dual-era protocol.** We serve both the modern stateless revision (2026-07-28) and the legacy `initialize` handshake, on both the client and server side. Most deployed clients still speak legacy, and refusing them costs revenue for no benefit.
- **Billing on errors.** A `tools/call` that reaches the upstream and returns a result is billed, including a result with `isError: true` — the upstream did the work and returned something actionable. Transport and protocol failures (timeout, unavailable, upstream JSON-RPC error) are refunded automatically in the same request.

## Not yet decided

Update this section as items are settled, then delete the ones that are.

- **Argument pinning.** Some upstream tools take a parameter that selects the data source, and one choice may point at a provider whose terms we have not reviewed (the USGS earthquake server's `source=emsc`). Those tools are excluded for now. A way to pin an argument server-side would let us re-enable them.
- **Caching.** Several providers throttle by client, and our whole fleet looks like one client to them. A short response cache would cut upstream load, but check each provider's terms first: some restrict caching.
- **Top-up provider.** The ledger is ready; the checkout integration is not.
- **Public home page URL** for the gateway, needed for the link rules above.
- **Re-verification schedule.** `Compliance.stale?/2` delists automatically, but nothing yet re-checks terms on a timer and opens an issue.
