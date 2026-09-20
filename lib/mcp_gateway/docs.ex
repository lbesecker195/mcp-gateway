defmodule McpGateway.Docs do
  @moduledoc """
  Generates the agent-facing documentation surface: `llms.txt`, `llms-full.txt`, `agent.txt`,
  `skill.txt`, `server.json`, and the per-server and per-tool markdown pages.

  Every document is rendered from `McpGateway.Catalog`, whose queries are already filtered to
  servers that are compliance-allowed, freshly verified and active. Nothing here writes its own
  query, so a server that stops being routable disappears from the docs in the same instant.

  Three things are deliberately never rendered:

    * a server's `upstream` field — its launch command, arguments and environment are internal
      infrastructure and may reference credentials. Only the *provider* (terms, attribution,
      rate limit, API docs) is public;
    * a hardcoded price. Every figure comes from `McpGateway.Settings.price_micro_usd/0`, by way
      of `McpGateway.RegistryJSON.pricing/0` or `McpGateway.Billing.format_usd/1`;
    * a guarantee the gateway does not implement. These files are read by agents that spend
      money on what they say, so a promise here is a promise in code. In particular there is no
      client-supplied idempotency key anywhere in the request path: `McpGateway.Gateway` mints a
      fresh call id per accepted POST and `McpGateway.Billing.charge/4` is idempotent only on
      that server-minted id. `agent.txt` says exactly that, and its retry advice follows from it.
  """

  alias McpGateway.Billing
  alias McpGateway.Catalog
  alias McpGateway.Catalog.{Server, Tool}
  alias McpGateway.MCP.Protocol, as: P
  alias McpGateway.RegistryJSON
  alias McpGateway.Settings

  @title "Phoenix MCP Gateway"

  # Recipe shaping for skill.txt. Recipes are generated, never hand-written, so these only bound
  # how much of the catalog one file describes.
  @recipe_tools 3
  @max_recipes 4

  ## ---------------------------------------------------------------------- llms.txt

  @doc """
  The `llms.txt` index (https://llmstxt.org): an H1, a blockquote summary, then H2 sections of
  links. Short on purpose — it points at the other documents rather than repeating them.
  """
  def llms_txt do
    servers = Catalog.list_servers_with_tools()
    base = Settings.base_url()

    join([
      "# #{@title}",
      "",
      "> #{summary(servers)}",
      "",
      connect_paragraph(servers, base),
      "",
      "## Start here",
      "",
      start_here(base),
      "",
      "## Servers",
      "",
      server_links(servers, base),
      "",
      "## Pricing",
      "",
      pricing_bullets(base),
      ""
    ])
  end

  @doc "The same index with every routable tool inlined: parameters, price, provider, attribution."
  def llms_full_txt do
    servers = Catalog.list_servers_with_tools()
    base = Settings.base_url()

    join([
      "# #{@title}: full tool reference",
      "",
      "> #{summary(servers)}",
      "",
      connect_paragraph(servers, base),
      "",
      "Every tool listed here is routable right now. This file is generated from the catalog,",
      "so a tool that is delisted for compliance reasons vanishes from it at the same moment.",
      "",
      "## Start here",
      "",
      start_here(base),
      "",
      "## Pricing",
      "",
      pricing_bullets(base),
      "",
      full_servers(servers, base),
      ""
    ])
  end

  ## ---------------------------------------------------------------------- agent.txt

  @doc """
  Plain-text operating instructions for an autonomous agent: endpoint, protocol versions, auth,
  what is free, what a call costs, how credit works, which failures are safe to retry, what 402
  and 429 mean, refunds, and a worked request/response pair taken from the live catalog.

  Sections 6 and 7 are the ones that have to stay true to `McpGateway.Gateway`. The gateway
  charges per accepted POST under an id it mints itself; there is no client idempotency key, so
  a retry is a new call and is billed as one. Everything the file says about retrying is derived
  from that, not from an aspiration.
  """
  def agent_txt do
    servers = Catalog.list_servers_with_tools()
    base = Settings.base_url()
    pricing = RegistryJSON.pricing()
    example = example_tool(servers)

    join([
      "#{String.upcase(@title)}: INSTRUCTIONS FOR AUTONOMOUS AGENTS",
      "Gateway version #{Settings.server_version()}. Generated from the live catalog on #{Date.utc_today()}.",
      "Free to read, no authentication needed. Everything below describes what is routable now.",
      "",
      "1. ENDPOINT",
      "   POST #{base}/mcp",
      "   Transport: MCP Streamable HTTP, one JSON-RPC request per POST.",
      "   POST #{base}/mcp/<slug> narrows the endpoint to a single upstream server.",
      "   Send with every POST:",
      "     Content-Type: application/json",
      "     Accept: application/json, text/event-stream",
      "   The response is either application/json or a text/event-stream SSE stream; handle both.",
      "",
      "2. PROTOCOL VERSIONS",
      "   Modern (stateless, no initialize handshake): #{Enum.join(P.modern_versions(), ", ")}",
      "   Legacy (initialize handshake, Mcp-Session-Id): #{Enum.join(P.legacy_versions(), ", ")}",
      "   On a modern request, params._meta MUST carry both of these keys:",
      "     \"#{P.meta_version_key()}\"",
      "     \"#{P.meta_client_caps_key()}\"",
      "   Omit either one and the request is refused with JSON-RPC #{P.invalid_params()} and HTTP 400.",
      "   Every POST MUST also carry these headers:",
      "     MCP-Protocol-Version: <the same version string as params._meta>",
      "     Mcp-Method: <the JSON-RPC method>",
      "     Mcp-Name: <params.name>            (required on tools/call)",
      "   Error codes you may see:",
      "     #{P.header_mismatch()}  HeaderMismatch               a header disagrees with the body (HTTP 400)",
      "     #{P.missing_capability()}  MissingRequiredClientCapability  a needed client capability was not declared",
      "     #{P.unsupported_version()}  UnsupportedProtocolVersion   retry with one of the versions above (HTTP 400)",
      "   Modern results always carry \"resultType\": \"complete\".",
      "",
      "3. AUTHENTICATION",
      "   Authorization: Bearer <your gateway API key>",
      "   Required on every request to the MCP endpoint, including the free ones, because the key",
      "   identifies the account whose balance a tools/call draws down.",
      "   A missing, unknown or revoked key is refused with HTTP #{P.unauthorized()}. Keys are stored hashed:",
      "   a lost key cannot be recovered, only replaced.",
      "   The documentation and registry URLs in section 12 need no key at all.",
      "",
      "   HOW TO GET A KEY",
      "   If you do not have one, create an account and claim the free trial in one request:",
      "",
      "     POST #{base}/v1/signup",
      "     Content-Type: application/json",
      "     {\"name\": \"a label for this account\"}",
      "",
      "   The response carries the key and the credit:",
      "     {",
      "       \"apiKey\": \"mcpg_...\",",
      "       \"creditUsd\": \"#{usd_plain(trial_credit())}\",",
      "       \"callsIncluded\": #{trial_calls()},",
      "       \"endpoint\": \"#{base}/mcp\"",
      "     }",
      "",
      "   The key is returned once and never again: only its hash is stored. Save it before you",
      "   make another request. No card, no subscription, and the credit is ordinary balance -",
      "   it is spent by the same #{price_usd()} per call as anything else.",
      "",
      "4. WHAT IS FREE AND WHAT IS CHARGED",
      "   FREE, never billed: #{Enum.join(pricing["freeOperations"], ", ")}.",
      "   FREE and unauthenticated: llms.txt, llms-full.txt, agent.txt, skill.txt, server.json and",
      "   every /docs page.",
      "   CHARGED: tools/call, and only tools/call.",
      "   A tools/call is charged once it reaches the upstream and the upstream returns a result.",
      "   That includes a result carrying \"isError\": true from the upstream: a provider that comes",
      "   back with \"no such city\" or \"date out of range\" did the work and handed you something to",
      "   correct against, and it costs the same as an answer you liked.",
      "   NOT charged: anything refused before the upstream is contacted (an unknown tool, a",
      "   malformed or mis-headered request, #{P.payment_required()}, #{P.rate_limited()}), and a call whose upstream never",
      "   returned a result at all - timeout, upstream unavailable, or a protocol error. That last",
      "   kind is charged and then refunded inside the same request; see section 10.",
      "   Careful: the gateway reports those upstream failures to you as a result with",
      "   \"isError\": true as well, so \"isError\" on its own does not tell you whether you paid. The",
      "   call record in section 6 does.",
      "",
      "5. PRICE",
      "   #{pricing["pricePerCallMicroUsd"]} micro-USD per tool call = #{price_usd()} USD.",
      "   1 micro-USD = $#{Billing.format_usd(1)}. Balances, charges and refunds are whole micro-USD",
      "   integers, so nothing is ever rounded away.",
      "   Billed on: #{pricing["billedOn"]}.",
      "",
      "6. BILLING MODEL, CALL IDS, AND WHAT IDEMPOTENCY YOU ACTUALLY GET",
      "   Billing model: #{pricing["model"]}. Top up a balance, and each charged call draws",
      "   #{price_micro()} micro-USD from it.",
      "   The balance check and the charge happen BEFORE the upstream is contacted: a call you",
      "   cannot afford never reaches the provider.",
      "   Every charged call gets a call id, and the result carries it back to you:",
      "     \"_meta\": {",
      "       \"#{Settings.meta_key("call")}\": { \"id\": \"<uuid>\", \"chargedMicroUsd\": #{price_micro()} }",
      "     }",
      "   The gateway attaches that record to charged calls and to nothing else, so its presence is",
      "   how you tell a billed result from a free one. Keep the id with whatever you did with the",
      "   result: it is the ledger's key for that charge, and it is what an automatic refund",
      "   (section 10) reverses.",
      "   The ledger is append-only and a given call id can be charged only once. Be precise about",
      "   what that does and does not buy you, because it is not request idempotency: the gateway",
      "   mints a fresh call id for every POST it accepts, so two POSTs are two ids and two charges",
      "   even when the two requests are byte-for-byte identical. This revision of the protocol has",
      "   no client-supplied idempotency key, and the gateway offers none of its own. Read section 7",
      "   before you retry anything.",
      "",
      "7. RETRYING SAFELY",
      "   The gateway cannot tell a retry from a new call, so whether retrying costs you anything",
      "   depends entirely on how the first attempt ended.",
      "   SAFE to repeat unchanged - the first attempt cost nothing:",
      "     - HTTP 400: a protocol or header problem (#{P.header_mismatch()}, #{P.unsupported_version()}, or #{P.invalid_params()} for a",
      "       missing params._meta key). Fix the request first; an identical retry fails identically.",
      "     - HTTP #{P.unauthorized()}: nothing runs without a valid key.",
      "     - HTTP #{P.payment_required()}: see section 8. Top up first.",
      "     - HTTP #{P.rate_limited()}: see section 9. Wait out Retry-After first.",
      "     - HTTP 200 carrying a JSON-RPC error instead of a result (an unknown tool, arguments the",
      "       upstream rejected). Nothing was charged, or a charge was already refunded.",
      "     - HTTP 200 with a result that has no call record in its _meta: the upstream returned",
      "       nothing and the charge was refunded in that same request.",
      "   NOT SAFE to repeat - you will pay again:",
      "     - HTTP 200 with a call record. That call is paid for and done, including when the result",
      "       said \"isError\": true. Sending it again buys a second call at #{price_micro()} micro-USD.",
      "     - No response at all. A client timeout, a dropped connection or a proxy reset tells you",
      "       nothing about what happened at this end: the call may well have been charged and",
      "       completed, and its call id went missing along with the response. Repeat it and the",
      "       gateway mints a second id, writes a second charge, and calls the provider again.",
      "   The gateway exposes no endpoint for asking, after the fact, whether a particular attempt",
      "   was charged, so a lost response cannot be reconciled from your side. Repeat one only when",
      "   repeating it is harmless anyway - a read-only lookup, or a tool whose tools/list",
      "   annotations declare \"idempotentHint\": true - and when paying #{price_micro()} micro-USD twice is an",
      "   acceptable price for the answer. Otherwise treat the call as done and move on.",
      "",
      "8. HTTP 402 PAYMENT REQUIRED",
      "   Meaning: your balance cannot cover this call (#{price_micro()} micro-USD). Nothing was charged and",
      "   no upstream was contacted, so the call had no effect anywhere.",
      "   Recover: top the account up, then repeat the identical request. Retrying before topping up",
      "   cannot succeed. Free operations keep working at a zero balance, so you can still discover",
      "   tools while out of credit.",
      "   The JSON-RPC error carries code #{P.payment_required()}, and its data carries your balance and the price.",
      "",
      "9. HTTP 429 TOO MANY REQUESTS",
      "   Meaning: you went over the per-account rate limit. The call was not charged.",
      "   The response carries a Retry-After header. Its value is delta-seconds (RFC 9110): a whole",
      "   number of seconds to wait, rounded up. The JSON-RPC error data repeats the same delay as",
      "   \"retryAfterMs\", in milliseconds. Wait at least that long and then repeat the same request.",
      "   Do not retry sooner and do not open more connections: the limit is per account, not per",
      "   connection. Per-upstream limits exist too and are there to keep us inside each provider's",
      "   free tier.",
      "   The JSON-RPC error carries code #{P.rate_limited()}.",
      "",
      "10. REFUNDS",
      "   If a charged call then fails upstream (timeout, upstream unavailable, or a protocol",
      "   error), the charge is refunded to your balance automatically, inside the same request.",
      "   The gateway does this on its own; there is nothing for you to call and nothing to claim.",
      "   Refunds are idempotent per call id, so you are never refunded twice and never left paying",
      "   for a call that returned no result. You pay only for #{pricing["billedOn"]}.",
      "",
      "11. WORKED EXAMPLE: ONE PAID TOOL CALL",
      example_preamble(example),
      "",
      "--- request ---",
      http_request_lines(example_tool_name(example)),
      "",
      example_request_body(example),
      "",
      "--- response ---",
      "HTTP/1.1 200 OK",
      "Content-Type: application/json",
      "",
      example_response_body(),
      "",
      "   That exchange costs #{price_usd()} (#{price_micro()} micro-USD), and the call record in the",
      "   result's _meta is the receipt for it. The same request without the",
      "   \"#{P.meta_client_caps_key()}\" key in params._meta would have been",
      "   refused with #{P.invalid_params()} and HTTP 400, and would have cost nothing.",
      "",
      "12. FINDING TOOLS",
      "   tools/list on the endpoint above returns every routable tool, cursor-paginated, for free.",
      "   #{base}/llms.txt        index of this gateway",
      "   #{base}/llms-full.txt   every tool with parameters, price and attribution",
      "   #{base}/skill.txt       task recipes with their total cost",
      "   #{base}/server.json     registry-format description of this gateway",
      "   #{base}/v0.1/servers    MCP Registry API, cursor-paginated",
      "   #{base}/docs/servers/<slug> and #{base}/docs/tools/<name>",
      "   Catalog right now: #{count(length(servers), "server")}, #{count(tool_count(servers), "tool")}.",
      "",
      "13. ATTRIBUTION",
      attribution_roster(servers),
      ""
    ])
  end

  ## ---------------------------------------------------------------------- skill.txt

  @doc """
  Task recipes that chain catalog tools, with the cost of each computed as (calls x price).
  Recipes are derived from the tools actually in the catalog; an empty catalog yields no recipes
  rather than invented ones.
  """
  def skill_txt do
    servers = Catalog.list_servers_with_tools()
    base = Settings.base_url()
    recipes = recipes(servers)

    join([
      "#{String.upcase(@title)}: TASK RECIPES",
      "Generated from the live catalog on #{Date.utc_today()}. Every tool named below is routable",
      "right now; nothing here is hypothetical.",
      "",
      "Price per tool call: #{price_usd()} (#{price_micro()} micro-USD).",
      "Cost of a recipe = number of tool calls x that price.",
      "Discovery is free and is not counted: #{Enum.join(RegistryJSON.pricing()["freeOperations"], ", ")}.",
      "",
      recipe_section(recipes),
      "",
      "HOW TO RUN A RECIPE",
      "   1. Authenticate with: Authorization: Bearer <your gateway API key>",
      "   2. POST each step to #{base}/mcp as a tools/call request. #{base}/agent.txt has the exact",
      "      headers and a complete worked example.",
      "   3. Read each tool's parameters first, from tools/list or #{base}/docs/tools/<name>. Both free.",
      "   4. The costs above assume one call per step and no retries. Every POST is metered on its",
      "      own: a step you send twice is two calls and two charges, because there is no client",
      "      idempotency key. A call that failed upstream was refunded, so retrying that one costs",
      "      nothing extra; a call you were charged for costs again. #{base}/agent.txt, section 7,",
      "      says which failures are which.",
      ""
    ])
  end

  ## ---------------------------------------------------------------------- server.json

  @doc "This gateway's own `server.json`, with the live count of servable tools."
  def server_json do
    RegistryJSON.gateway_server(tool_count(Catalog.list_servers_with_tools()))
  end

  ## ---------------------------------------------------------------------- /docs pages

  @doc "Markdown for one servable server. `{:error, :not_found}` for anything else."
  def server_doc(slug) when is_binary(slug) do
    case Catalog.get_server_by_slug(slug) do
      nil -> {:error, :not_found}
      %Server{} = server -> {:ok, render_server_doc(server, all_tools(slug))}
    end
  end

  @doc "Markdown for one servable tool. `{:error, :not_found}` for anything else."
  def tool_doc(name) when is_binary(name) do
    case Catalog.fetch_tool(name) do
      {:ok, tool, server} -> {:ok, render_tool_doc(tool, server)}
      {:error, :unknown_tool} -> {:error, :not_found}
    end
  end

  defp render_server_doc(%Server{} = server, tools) do
    base = Settings.base_url()

    join([
      "# #{md_label(server)}",
      "",
      "`#{server.name}`, version #{server.version}",
      "",
      md_block(present(server.description)) || "No description supplied for this server.",
      "",
      gateway_facts(server, base),
      "",
      "## Provider",
      "",
      provider_table(server),
      "",
      "## Attribution",
      "",
      attribution_block(server),
      "",
      tools_table(server, tools, base),
      "",
      "## Price",
      "",
      pricing_bullets(base),
      ""
    ])
  end

  defp render_tool_doc(%Tool{} = tool, %Server{} = server) do
    base = Settings.base_url()
    definition = Tool.to_mcp(tool)
    schema = definition["inputSchema"]

    join([
      "# `#{tool.name}`",
      "",
      present(tool.title) && "**#{md(tool.title)}**",
      present(tool.title) && "",
      md_block(present(tool.description)) ||
        "The upstream server supplies no description for this tool.",
      "",
      tool_facts(tool, server, base),
      "",
      "## Parameters",
      "",
      parameter_lines(schema),
      "",
      "## Example call",
      "",
      "Request headers and body:",
      "",
      "```http",
      http_request_lines(tool.name),
      "```",
      "",
      "```json",
      example_request_body({tool, server}),
      "```",
      "",
      "A successful response:",
      "",
      "```json",
      example_response_body(),
      "```",
      "",
      "This call costs #{price_usd()} (#{price_micro()} micro-USD). Reading this page and listing the tool cost nothing.",
      "The `#{Settings.meta_key("call")}` record in the result is the receipt for that charge. Each",
      "POST is metered separately, so sending the same call again buys another one: see",
      "[agent.txt](#{base}/agent.txt), section 7, before retrying.",
      "",
      "## Attribution",
      "",
      attribution_block(server),
      "",
      "## Tool definition",
      "",
      "Exactly as `tools/list` returns it (free):",
      "",
      "```json",
      json(definition),
      "```",
      ""
    ])
  end

  ## ---------------------------------------------------------------------- shared prose

  defp summary(servers) do
    "One metered MCP endpoint in front of #{count(length(servers), "MCP server")} wrapping free and " <>
      "freemium APIs, exposing #{count(tool_count(servers), "tool")}. Each tools/call costs " <>
      "#{price_usd()} (#{price_micro()} micro-USD) from prepaid credits; discovery is free."
  end

  defp connect_paragraph(servers, base) do
    "Connect over MCP Streamable HTTP to `#{base}/mcp` with the header " <>
      "`Authorization: Bearer <your gateway API key>`. Supported protocol versions: " <>
      "#{Enum.join(P.modern_versions(), ", ")} (modern, stateless) and " <>
      "#{Enum.join(P.legacy_versions(), ", ")} (legacy, `initialize` handshake). Tool names are " <>
      "namespaced by server#{example_name_clause(servers)}. Read " <>
      "[agent.txt](#{base}/agent.txt) before your first paid call."
  end

  defp example_name_clause(servers) do
    case example_tool(servers) do
      {tool, _server} -> ", for example `#{tool.name}`"
      nil -> ""
    end
  end

  defp start_here(base) do
    [
      "- [agent.txt](#{base}/agent.txt): How to authenticate, what a call costs, which failures are safe to retry, and how to handle 402 and 429.",
      "- [skill.txt](#{base}/skill.txt): Task recipes that chain tools across servers, with the cost of each.",
      "- [llms-full.txt](#{base}/llms-full.txt): Every routable tool with its parameters, price and attribution.",
      "- [server.json](#{base}/server.json): Registry-format description of this gateway.",
      "- [Registry API](#{base}/v0.1/servers): Cursor-paginated catalog of every routable server."
    ]
  end

  defp server_links([], base) do
    "No servers are routable right now. The [registry API](#{base}/v0.1/servers) lists them as " <>
      "soon as they clear the compliance gate."
  end

  defp server_links(servers, base), do: Enum.map(servers, &server_link(&1, base))

  defp server_link(server, base) do
    "- [#{md_label(server)}](#{base}/docs/servers/#{server.slug}): " <>
      "#{md(server.description)} #{count(length(server.tools), "tool")}."
  end

  # The retry bullet is not a nicety. Every POST is metered on its own, so an agent that treats a
  # repeat as free is wrong about the price of its own plan.
  defp pricing_bullets(base) do
    pricing = RegistryJSON.pricing()

    [
      "- #{price_usd()} (#{pricing["pricePerCallMicroUsd"]} micro-USD) per tool call.",
      "- Billed on: #{pricing["billedOn"]}.",
      "- Free: #{Enum.join(pricing["freeOperations"], ", ")}.",
      "- Payment: #{pricing["model"]}. A call your balance cannot cover is refused with HTTP 402 before any upstream is contacted.",
      "- A charged call that then fails upstream is refunded automatically.",
      "- Retries are ordinary calls. There is no client idempotency key, so repeating a request that was already charged buys a second call - see [agent.txt](#{base}/agent.txt), section 7."
    ]
  end

  ## ---------------------------------------------------------------------- llms-full.txt bodies

  defp full_servers([], _base) do
    ["## Servers", "", "No servers are routable right now, so this file lists no tools."]
  end

  defp full_servers(servers, base), do: Enum.map(servers, &full_server(&1, base))

  defp full_server(server, base) do
    [
      "## #{md_label(server)} (`#{server.slug}`)",
      "",
      md_block(present(server.description)) || "No description supplied for this server.",
      "",
      server_facts(server, base),
      "",
      full_tools(server, base),
      ""
    ]
  end

  defp full_tools(%Server{tools: []}, _base) do
    "This server currently exposes no tools."
  end

  defp full_tools(server, base) do
    Enum.map(server.tools, fn tool ->
      [
        "### `#{tool.name}`",
        "",
        blank_to(md(tool.description), "No description supplied by the upstream server."),
        "",
        "- Price: #{price_usd()} (#{price_micro()} micro-USD) per call.",
        "- Provider: #{md_label(server)}, terms #{terms_text(server)}.",
        "- Attribution: #{attribution(server) || "not required by this provider."}",
        "- Tool documentation: <#{base}/docs/tools/#{tool.name}>",
        "",
        "Parameters:",
        "",
        parameter_lines(tool.input_schema),
        ""
      ]
    end)
  end

  ## ---------------------------------------------------------------------- facts and tables

  # How to reach this server through the gateway. The provider's own facts live in the table
  # below it on the same page, so they are not repeated here.
  defp gateway_facts(%Server{} = server, base) do
    [
      fact(
        "MCP endpoint",
        "`#{base}/mcp/#{server.slug}` for this server alone, or `#{base}/mcp` for every server"
      ),
      fact("Authentication", "`Authorization: Bearer <your gateway API key>`"),
      fact("Price per tool call", "#{price_usd()} (#{price_micro()} micro-USD)"),
      fact("Registry entry", "<#{registry_url(server, base)}>"),
      fact("Every tool, machine-readable", "<#{base}/llms-full.txt>")
    ]
  end

  defp server_facts(%Server{} = server, base) do
    compliance = compliance_map(server)

    [
      fact("Server name", "`#{server.name}` (version #{server.version})"),
      fact(
        "MCP endpoint",
        "`#{base}/mcp/#{server.slug}` for this server alone, or `#{base}/mcp` for every server"
      ),
      fact("Authentication", "`Authorization: Bearer <your gateway API key>`"),
      fact("Price per tool call", "#{price_usd()} (#{price_micro()} micro-USD)"),
      fact("Documentation", "<#{base}/docs/servers/#{server.slug}>"),
      fact("Registry entry", "<#{registry_url(server, base)}>"),
      fact("Provider terms", terms_text(server)),
      fact("Upstream API documentation", url_text(compliance["api_docs_url"])),
      fact("Upstream API key", key_text(compliance["key_required"])),
      fact("Rate limit", rate_limit_text(server.rate_limit)),
      fact("Website", url_text(server.website_url)),
      fact("Attribution required", attribution(server))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp tool_facts(%Tool{} = tool, %Server{} = server, base) do
    compliance = compliance_map(server)

    [
      fact(
        "Server",
        "[#{md_label(server)}](#{base}/docs/servers/#{server.slug}) (`#{server.name}`)"
      ),
      fact(
        "Price per call",
        "#{price_usd()} (#{price_micro()} micro-USD); only tools/call is charged"
      ),
      fact("Endpoint", "`#{base}/mcp` or `#{base}/mcp/#{server.slug}`"),
      fact(
        "Upstream tool",
        "exposed by the provider; called through this gateway as `#{tool.name}`"
      ),
      fact("Provider terms", terms_text(server)),
      fact("Upstream API documentation", url_text(compliance["api_docs_url"])),
      fact("Rate limit", rate_limit_text(server.rate_limit)),
      fact("Attribution required", attribution(server))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp fact(_label, nil), do: nil
  defp fact(label, value), do: "- #{label}: #{value}"

  defp provider_table(%Server{} = server) do
    compliance = compliance_map(server)

    rows =
      [
        {"Terms of use", url_text(compliance["terms_url"])},
        {"Terms verified on", Date.to_iso8601(server.compliance_checked_on)},
        {"API documentation", url_text(compliance["api_docs_url"])},
        {"Upstream API key", key_text(compliance["key_required"])},
        {"Rate limit", rate_limit_text(server.rate_limit)},
        {"Website", url_text(server.website_url)},
        {"Compliance notes", present(compliance["notes"]) && cell(compliance["notes"])}
      ]
      |> Enum.reject(fn {_label, value} -> is_nil(value) end)
      |> Enum.map(fn {label, value} -> "| #{label} | #{value} |" end)

    [
      "We proxy this provider under the terms below, re-checked on a schedule. If a re-check ever",
      "says no, the server and its tools leave the catalog and this page disappears with them.",
      "",
      "| Fact | Value |",
      "| --- | --- |"
    ] ++ rows
  end

  defp tools_table(%Server{} = server, [], base) do
    [
      "## Tools (0)",
      "",
      "This server exposes no tools right now. `tools/list` on `#{base}/mcp/#{server.slug}` is free",
      "and always current."
    ]
  end

  defp tools_table(_server, tools, base) do
    rows =
      Enum.map(tools, fn tool ->
        "| `#{tool.name}` | #{md(tool.description)} | #{price_usd()} | [#{tool.name}](#{base}/docs/tools/#{tool.name}) |"
      end)

    [
      "## Tools (#{length(tools)})",
      "",
      "Every call below costs #{price_usd()} (#{price_micro()} micro-USD). Listing them costs nothing.",
      "",
      "| Tool | Description | Price per call | Documentation |",
      "| --- | --- | --- | --- |"
    ] ++ rows
  end

  ## ---------------------------------------------------------------------- attribution

  # Attribution strings are our own reviewed compliance data, and the agent is asked to reproduce
  # them verbatim, so they are not markdown-escaped: backslashes would end up in the credit line.
  defp attribution_block(%Server{} = server) do
    case attribution(server) do
      nil ->
        "This provider asks for no attribution. Their terms still apply: see the table above."

      text ->
        [
          "This provider requires the attribution below wherever you use results from its tools.",
          "Reproduce it verbatim:",
          "",
          "> #{cell(text)}"
        ]
    end
  end

  defp attribution_roster(servers) do
    attributed =
      servers
      |> Enum.map(fn server -> {server, attribution(server)} end)
      |> Enum.reject(fn {_server, text} -> is_nil(text) end)

    case attributed do
      [] ->
        [
          "   No routable server requires attribution right now. Check this section again after the",
          "   catalog changes; the requirement travels with the data, not with the gateway."
        ]

      list ->
        [
          "   Some providers require an attribution string wherever their data is used. Reproduce it",
          "   verbatim in anything you produce from these tools:"
        ] ++
          Enum.map(list, fn {server, text} ->
            "     - #{server_label(server)} (#{server.slug}): #{cell(text)}"
          end)
    end
  end

  defp attribution(%Server{} = server), do: present(compliance_map(server)["attribution"])

  ## ---------------------------------------------------------------------- recipes

  defp recipes(servers) do
    stocked = Enum.filter(servers, &(&1.tools != []))

    pairs =
      stocked
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> pair_recipe(a, b) end)
      |> Enum.take(@max_recipes)

    singles = stocked |> Enum.map(&single_recipe/1) |> Enum.take(@max_recipes)

    pairs ++ singles
  end

  defp pair_recipe(a, b) do
    first = lead_tool(a)
    second = lead_tool(b)

    %{
      goal:
        "Combine #{server_label(a)} with #{server_label(b)}: call `#{first.name}`, then use what " <>
          "it returns as the input to `#{second.name}`.",
      steps: [{first, a}, {second, b}]
    }
  end

  defp single_recipe(server) do
    tools = server |> ordered_tools() |> Enum.take(@recipe_tools)

    %{
      goal: "Work through #{server_label(server)}: #{cell(server.description)}",
      steps: Enum.map(tools, &{&1, server})
    }
  end

  # A chain reads better when it starts with the tool that looks up something. This only reorders
  # tools that are already in the catalog; it never invents a step.
  @lookup ~r/search|find|list|query|lookup/i

  defp lead_tool(server) do
    Enum.find(server.tools, &Regex.match?(@lookup, "#{&1.name} #{&1.description}")) ||
      hd(server.tools)
  end

  defp ordered_tools(server) do
    lead = lead_tool(server)
    [lead | Enum.reject(server.tools, &(&1.id == lead.id))]
  end

  defp recipe_section([]) do
    [
      "NO RECIPES",
      "   The catalog exposes no routable tools right now, so there is nothing to chain and this",
      "   file invents nothing. Call tools/list (free) and re-read this file once it returns tools."
    ]
  end

  defp recipe_section(recipes) do
    recipes
    |> Enum.with_index(1)
    |> Enum.map(fn {recipe, index} -> recipe_lines(recipe, index) end)
  end

  defp recipe_lines(%{goal: goal, steps: steps}, index) do
    calls = length(steps)

    servers =
      steps
      |> Enum.map(fn {_tool, server} -> server end)
      |> Enum.uniq_by(& &1.id)

    attributions =
      servers
      |> Enum.map(fn server -> {server, attribution(server)} end)
      |> Enum.reject(fn {_server, text} -> is_nil(text) end)
      |> Enum.map(fn {server, text} ->
        "   Attribution (#{server_label(server)}): #{cell(text)}"
      end)

    [
      "RECIPE #{index}",
      "   Goal: #{goal}",
      "   Servers: #{Enum.map_join(servers, ", ", &"#{server_label(&1)} (#{&1.slug})")}",
      "   Steps:",
      steps
      |> Enum.with_index(1)
      |> Enum.map(fn {{tool, _server}, step} ->
        "     #{step}. tools/call #{tool.name} -- #{cell(tool.description) |> blank_to("no description supplied")}"
      end),
      "   Tool calls: #{calls}",
      "   Cost: #{calls} x #{price_usd()} = #{usd(calls * price_micro())} (one attempt each)",
      attributions,
      ""
    ]
  end

  ## ---------------------------------------------------------------------- example call

  defp example_preamble({tool, server}) do
    [
      "   `#{tool.name}` below is a real entry in this catalog, from #{server_label(server)}.",
      "   Substitute any tool name that tools/list returns."
    ]
  end

  defp example_preamble(nil) do
    [
      "   The catalog exposes no tools right now, so <tool-name> below is a placeholder.",
      "   Call tools/list (free) and substitute a name it returns."
    ]
  end

  defp example_tool_name({tool, _server}), do: tool.name
  defp example_tool_name(nil), do: "<tool-name>"

  defp http_request_lines(tool_name) do
    uri = URI.parse(Settings.base_url())

    [
      "POST /mcp HTTP/1.1",
      "Host: #{uri.authority || uri.host}",
      "Authorization: Bearer <your gateway API key>",
      "Content-Type: application/json",
      "Accept: application/json, text/event-stream",
      "MCP-Protocol-Version: #{modern_version()}",
      "Mcp-Method: tools/call",
      "Mcp-Name: #{P.encode_header_value(tool_name)}"
    ]
  end

  defp example_request_body({tool, _server}) do
    request_json(tool.name, example_arguments(tool.input_schema))
  end

  defp example_request_body(nil), do: request_json("<tool-name>", %{})

  defp request_json(tool_name, arguments) do
    json(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => arguments,
        "_meta" => %{
          P.meta_version_key() => modern_version(),
          P.meta_client_info_key() => %{"name" => "example-agent", "version" => "1.0.0"},
          P.meta_client_caps_key() => %{}
        }
      }
    })
  end

  # The call record is part of a charged response, so the worked example shows it. An agent that
  # reads section 6 and then this example must see the same shape in both places.
  defp example_response_body do
    json(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => %{
        "resultType" => "complete",
        "content" => [%{"type" => "text", "text" => "<whatever the upstream tool returned>"}],
        "_meta" => %{
          Settings.meta_key("call") => %{
            "id" => "<the id of this charge>",
            "chargedMicroUsd" => price_micro()
          }
        }
      }
    })
  end

  defp example_arguments(schema) when is_map(schema) do
    props = schema["properties"]
    required = schema["required"]
    required = if is_list(required), do: Enum.filter(required, &is_binary/1), else: []

    if is_map(props) and map_size(props) > 0 do
      names =
        case required do
          [] -> props |> Map.keys() |> Enum.sort() |> Enum.take(1)
          names -> names
        end

      Map.new(names, fn name -> {name, placeholder(props[name])} end)
    else
      %{}
    end
  end

  defp example_arguments(_schema), do: %{}

  defp placeholder(spec) when is_map(spec) do
    case spec["enum"] do
      [first | _] -> first
      _ -> placeholder_for(spec["type"])
    end
  end

  defp placeholder(_spec), do: "example"

  defp placeholder_for("integer"), do: 1
  defp placeholder_for("number"), do: 1
  defp placeholder_for("boolean"), do: true
  defp placeholder_for("array"), do: []
  defp placeholder_for("object"), do: %{}
  defp placeholder_for([first | _]), do: placeholder_for(first)
  defp placeholder_for(_type), do: "example"

  ## ---------------------------------------------------------------------- parameters

  defp parameter_lines(schema) do
    props = if is_map(schema), do: schema["properties"], else: nil
    required = if is_map(schema), do: schema["required"], else: nil
    required = if is_list(required), do: required, else: []

    if is_map(props) and map_size(props) > 0 do
      props
      |> Enum.sort_by(fn {name, _spec} -> name end)
      |> Enum.map(fn {name, spec} -> parameter_line(name, spec, name in required) end)
    else
      ["- This tool takes no parameters. Send `\"arguments\": {}`."]
    end
  end

  defp parameter_line(name, spec, required?) do
    spec = if is_map(spec), do: spec, else: %{}

    head =
      "- `#{code(name)}` (#{type_text(spec["type"])}, #{if required?, do: "required", else: "optional"})"

    extras =
      [
        present(spec["description"]) && md(spec["description"]),
        enum_text(spec["enum"]),
        default_text(spec)
      ]
      |> Enum.reject(&is_nil/1)

    case extras do
      [] -> head
      list -> head <> ": " <> Enum.join(list, " ")
    end
  end

  defp type_text(type) when is_binary(type), do: code(type)
  defp type_text(types) when is_list(types), do: Enum.map_join(types, " or ", &type_text/1)
  defp type_text(_type), do: "any"

  defp enum_text(values) when is_list(values) and values != [] do
    "One of: " <> Enum.map_join(values, ", ", &"`#{code(inspect_value(&1))}`") <> "."
  end

  defp enum_text(_values), do: nil

  defp default_text(%{"default" => value}) when not is_nil(value),
    do: "Default: `#{code(inspect_value(value))}`."

  defp default_text(_spec), do: nil

  defp inspect_value(value) when is_binary(value), do: value
  defp inspect_value(value), do: Jason.encode!(value)

  ## ---------------------------------------------------------------------- catalog helpers

  # Pages through the catalog's own scoped query. Never a hand-rolled query: the scope is what
  # keeps a non-servable server's tools out of the docs.
  defp all_tools(slug, cursor \\ nil, acc \\ []) do
    case Catalog.list_tools(scope: slug, cursor: cursor) do
      {:ok, %{tools: tools, next_cursor: nil}} -> acc ++ tools
      {:ok, %{tools: tools, next_cursor: next}} -> all_tools(slug, next, acc ++ tools)
      {:error, _reason} -> acc
    end
  end

  # The tool the worked examples are built from. A tool with parameters teaches more than one
  # without, so it wins; either way the example names a tool that is genuinely routable.
  defp example_tool(servers) do
    tools = Enum.flat_map(servers, fn server -> Enum.map(server.tools, &{&1, server}) end)

    Enum.find(tools, fn {tool, _server} -> parameters?(tool.input_schema) end) ||
      List.first(tools)
  end

  defp parameters?(schema) when is_map(schema) do
    props = schema["properties"]
    is_map(props) and map_size(props) > 0
  end

  defp parameters?(_schema), do: false

  defp tool_count(servers), do: servers |> Enum.map(&length(&1.tools)) |> Enum.sum()

  # The plain-text label, for agent.txt and skill.txt. Markdown pages use `md_label/1`.
  defp server_label(%Server{} = server), do: present(server.title) || server.name

  defp md_label(%Server{} = server), do: md(server_label(server))

  defp registry_url(%Server{} = server, base) do
    "#{base}/v0.1/servers/#{URI.encode(server.name, &URI.char_unreserved?/1)}/versions/latest"
  end

  defp compliance_map(%Server{compliance: compliance}) when is_map(compliance), do: compliance
  defp compliance_map(_server), do: %{}

  defp terms_text(%Server{} = server) do
    verified = "verified #{Date.to_iso8601(server.compliance_checked_on)}"

    case present(compliance_map(server)["terms_url"]) do
      nil -> verified
      url -> "<#{url}> (#{verified})"
    end
  end

  defp url_text(url) do
    case present(url) do
      nil -> nil
      value -> "<#{value}>"
    end
  end

  # The upstream's key requirement, never the key itself or the variable that holds it.
  defp key_text(nil), do: nil
  defp key_text("none"), do: "none required"

  defp key_text(value) when is_binary(value) do
    "#{value}; supplied by the gateway, so never send upstream credentials to this endpoint"
  end

  defp key_text(_value), do: nil

  defp rate_limit_text(%{"requests" => requests, "window_ms" => window})
       when is_integer(requests) and is_integer(window) and window > 0 do
    "#{count(requests, "request")} per #{window_text(window)}"
  end

  defp rate_limit_text(limit) when is_map(limit) and map_size(limit) > 0 do
    limit
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}: #{inspect_value(value)}" end)
  end

  defp rate_limit_text(_limit), do: nil

  defp window_text(ms) do
    cond do
      rem(ms, 3_600_000) == 0 -> unit(div(ms, 3_600_000), "hour")
      rem(ms, 60_000) == 0 -> unit(div(ms, 60_000), "minute")
      rem(ms, 1_000) == 0 -> unit(div(ms, 1_000), "second")
      true -> "#{ms} ms"
    end
  end

  defp unit(1, word), do: word
  defp unit(n, word), do: "#{n} #{word}s"

  ## ---------------------------------------------------------------------- money

  defp trial_credit, do: Settings.trial_credit_micro_usd()
  defp trial_calls, do: div(trial_credit(), Settings.price_micro_usd())
  defp usd_plain(micro), do: Billing.format_usd(micro)

  defp price_micro, do: Settings.price_micro_usd()
  defp price_usd, do: usd(price_micro())
  defp usd(micro), do: "$" <> Billing.format_usd(micro)

  defp modern_version, do: hd(P.modern_versions())

  ## ---------------------------------------------------------------------- text helpers

  defp join(parts) do
    parts
    |> List.flatten()
    |> Enum.reject(&(is_nil(&1) or &1 == false))
    |> Enum.join("\n")
  end

  defp count(n, word), do: "#{n} #{word}#{if n == 1, do: "", else: "s"}"

  # Collapses a description to one table- and line-safe fragment. Plain text only: use `md/1` for
  # anything that lands in a markdown document.
  defp cell(nil), do: ""

  defp cell(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.replace("|", "\\|")
    |> truncate(200)
  end

  defp cell(_text), do: ""

  defp blank_to(nil, fallback), do: fallback
  defp blank_to("", fallback), do: fallback
  defp blank_to(text, _fallback), do: text

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 3) <> "...", else: text
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp json(term), do: Jason.encode!(term, pretty: true)

  ## ------------------------------------------------- upstream text in a markdown document

  # Upstream servers supply tool names, titles, descriptions and schema text, and those strings
  # end up inside our markdown pages. The escaping below is structural rather than cosmetic: what
  # must not survive is a character that changes the shape of the document instead of its
  # wording - a backtick or fence that breaks out into code, a `[..](..)` link or `<..>` autolink
  # aiming somewhere we did not choose, a raw HTML tag, a pipe that splits a table row, or a block
  # marker in column one. Emphasis characters mid-line are left alone: they cannot restructure
  # anything, and escaping them would fill descriptions with backslashes.
  @md_structural ~r/[`\[\]<>]/
  @md_leaders ~w(# > - + = ~ * _ |)

  defp md(nil), do: nil
  defp md(text) when is_binary(text), do: text |> cell() |> escape_md()
  defp md(_text), do: nil

  # The same protection without the one-line collapse, for the pages where the upstream's whole
  # description is the point rather than a table cell.
  defp md_block(nil), do: nil

  defp md_block(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map_join("\n", fn line ->
      line |> String.trim() |> String.replace("|", "\\|") |> escape_md()
    end)
  end

  defp md_block(_text), do: nil

  defp escape_md(text) do
    @md_structural
    |> Regex.replace(text, fn char -> "\\" <> char end)
    |> escape_leader()
  end

  defp escape_leader(<<char::binary-size(1), _rest::binary>> = text) when char in @md_leaders,
    do: "\\" <> text

  defp escape_leader(text), do: text

  # A value we wrap in a markdown code span: a backtick or a line break inside it would end the
  # span early and let the rest of the value escape into the document.
  defp code(value) when is_binary(value) do
    value |> String.replace(~r/[`\r\n]+/, " ") |> String.trim()
  end

  defp code(value), do: value
end
