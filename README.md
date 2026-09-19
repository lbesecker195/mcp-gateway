# MCP Gateway (Phoenix)

One metered MCP endpoint in front of many free and freemium APIs, at **$0.0001 per tool call**.

Clients connect to a single Model Context Protocol endpoint, discover tools for free, and pay
per call from a prepaid balance. Behind it, the gateway routes each call to a third-party MCP
server that wraps the upstream API.

```
MCP client ──▶ /mcp ──▶ auth ──▶ rate limit ──▶ charge 100 µUSD ──▶ upstream MCP server ──▶ API
                                                      └── refund automatically if the call fails
```

## What is in the catalog

Seventeen upstreams covering scholarly literature (arXiv, OpenAlex, Crossref, PubMed,
Europe PMC), chemistry (PubChem), government and economic data (SEC EDGAR, US Treasury, BLS,
World Bank, Frankfurter/ECB), earth and weather (NWS, USGS earthquakes, NOAA tides), space
(NASA), and package registries (npm, PyPI).

Every one of them was checked against its provider's terms before it was listed. Roughly a
third of the APIs we evaluated were rejected because their terms forbid exactly this model —
see [catalog/COMPLIANCE.md](catalog/COMPLIANCE.md), which records each verdict and why.

## Getting started

Requires Elixir, Erlang/OTP and PostgreSQL.

```bash
mix setup
```

Then import the catalog and start the server:

```bash
mix catalog.sync --offline
```

```bash
mix phx.server
```

The gateway is then at `http://localhost:4000`:

| Path | What it serves |
|---|---|
| `POST /mcp` | The MCP endpoint — every servable tool |
| `POST /mcp/:slug` | Scoped to one upstream |
| `GET /v0.1/servers` | MCP Registry API over the catalog |
| `GET /llms.txt`, `/agent.txt`, `/skill.txt` | Documentation written for agents |
| `GET /server.json` | The gateway's own registry entry |
| `GET /docs/tools/:name` | Per-tool documentation |

Discovery is free. Only `tools/call` is billed.

## Contributing

Read [AGENT.md](AGENT.md) first — it holds the rules that do not bend, chiefly that money is
handled in integer micro-USD and that no upstream is listed without a verified compliance
record.

```bash
mix precommit
```

## Licence

Apache-2.0. See [LICENSE](LICENSE).
