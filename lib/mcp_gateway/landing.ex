defmodule McpGateway.Landing do
  @moduledoc """
  The public landing page and sitemap, generated from the live catalog.

  This is the only HTML the gateway serves. It exists for two audiences that want opposite
  things, so it serves both from one document:

    * People and search engines, who arrive on `/` and need to know what an MCP gateway is,
      what this one costs, and what is in it. Search interest concentrates on the definitional
      query, so the page answers "what is an MCP gateway" in prose before it sells anything.
    * Agents, which are pointed at `llms.txt` and `agent.txt` from here and in `robots.txt`.

  The server list, tool counts and price are read from the catalog at request time, so the page
  can never advertise a provider that has been delisted or a price that has changed. That is
  the same rule the rest of the documentation surface follows.

  Every claim here has to stay true: the comparison figures are the ones we can support, and
  the keywords are terms that genuinely describe what this serves.
  """

  alias McpGateway.{Billing, Catalog, Settings}
  alias McpGateway.MCP.Protocol, as: P

  @description "A metered MCP gateway: one Model Context Protocol endpoint for public data APIs, billed per tool call."

  @doc "The landing page, as a complete HTML document."
  def html do
    servers = Catalog.list_servers_by_capacity()
    tools = servers |> Enum.map(&length(&1.tools)) |> Enum.sum()
    base = Settings.canonical_base_url()
    price = Billing.format_usd(Settings.price_micro_usd())

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>MCP Gateway — one Model Context Protocol endpoint for #{tools} tools, $#{price} per call</title>
    <meta name="description" content="#{esc(meta_description(servers, tools, price))}">
    <link rel="canonical" href="#{base}/">
    <meta property="og:type" content="website">
    <meta property="og:title" content="MCP Gateway — #{tools} tools, $#{price} per call">
    <meta property="og:description" content="#{esc(@description)}">
    <meta property="og:url" content="#{base}/">
    <meta name="twitter:card" content="summary">
    <meta name="robots" content="index,follow">
    <link rel="alternate" type="text/plain" href="#{base}/llms.txt" title="llms.txt">
    <script type="application/ld+json">#{jsonld(servers, tools, base, price)}</script>
    <style>#{css()}</style>
    </head>
    <body>
    <main>
    #{hero(servers, tools, price)}
    #{what_is_section()}
    #{trial_section()}
    #{pricing_section(price)}
    #{connect_section(base)}
    #{catalog_section(servers, base)}
    #{compliance_section()}
    #{agents_section(base)}
    </main>
    #{footer(base)}
    </body>
    </html>
    """
  end

  @doc "A sitemap covering the landing page, the agent documents and every servable entry."
  def sitemap_xml do
    base = Settings.canonical_base_url()
    servers = Catalog.list_servers_with_tools()

    urls =
      [
        {"#{base}/", "1.0"},
        {"#{base}/llms.txt", "0.8"},
        {"#{base}/agent.txt", "0.8"},
        {"#{base}/skill.txt", "0.6"},
        {"#{base}/v0.1/servers", "0.6"}
      ] ++
        Enum.map(servers, &{"#{base}/docs/servers/#{&1.slug}", "0.7"}) ++
        Enum.flat_map(servers, fn s ->
          Enum.map(s.tools, &{"#{base}/docs/tools/#{&1.name}", "0.5"})
        end)

    entries =
      Enum.map_join(urls, "\n", fn {loc, priority} ->
        "  <url><loc>#{esc(loc)}</loc><priority>#{priority}</priority></url>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{entries}
    </urlset>
    """
  end

  @doc "robots.txt, pointing crawlers and agents at the machine-readable documents."
  def robots_txt do
    base = Settings.canonical_base_url()

    """
    # Everything here is public and free to read.
    User-agent: *
    Allow: /

    # The MCP endpoint needs an API key and does nothing useful for a crawler.
    Disallow: /mcp

    Sitemap: #{base}/sitemap.xml

    # For agents: a machine-readable index of every routable tool and its price.
    # #{base}/llms.txt
    # #{base}/agent.txt
    """
  end

  # Search engines truncate around 160 characters, so this has to say what the gateway is,
  # how big it is and what it costs inside that budget.
  defp meta_description(servers, tools, price) do
    "One Model Context Protocol endpoint for #{tools} tools across #{length(servers)} MCP " <>
      "servers: arXiv, PubMed, SEC EDGAR, NOAA and more. $#{price} per tool call, no subscription."
  end

  ## ------------------------------------------------------------------ sections

  defp hero(servers, tools, price) do
    """
    <header>
      <h1>MCP Gateway</h1>
      <p class="lede">One <strong>Model Context Protocol</strong> endpoint for
      #{tools} tools across #{length(servers)} MCP servers &mdash; public data APIs for research,
      finance, weather and software, billed at <strong>$#{price} per tool call</strong>.</p>
      <p class="cta"><a class="btn" href="/try">Try it now</a>
      <a class="btn secondary" href="/agent.txt">Connect an agent</a></p>
      <dl class="stats">
        <div><dt>Tools</dt><dd>#{tools}</dd></div>
        <div><dt>MCP servers</dt><dd>#{length(servers)}</dd></div>
        <div><dt>Per call</dt><dd>$#{price}</dd></div>
        <div><dt>Subscription</dt><dd>None</dd></div>
      </dl>
    </header>
    """
  end

  defp what_is_section do
    """
    <section id="what-is-an-mcp-gateway">
      <h2>What is an MCP gateway?</h2>
      <p>The <a href="https://modelcontextprotocol.io">Model Context Protocol</a> (MCP) is an open
      standard that lets an AI agent discover and call tools without bespoke integration code for
      each one. An <strong>MCP gateway</strong> sits in front of many MCP servers and gives an
      agent a single endpoint: it routes each tool call to the right upstream server, and handles
      the cross-cutting concerns &mdash; authentication, rate limiting, metering and billing &mdash;
      in one place rather than in every server.</p>
      <p>Without a gateway, an agent that needs papers from arXiv, filings from SEC EDGAR and
      forecasts from the National Weather Service has to find, install, run and keep up to date
      three separate MCP servers, each with its own credentials and quota. With one, it connects
      once and calls any of them by name.</p>
      <p>This gateway adds two things most do not: it <strong>meters every call</strong> so you pay
      only for what you use, and it <strong>verifies each provider's terms</strong> before listing
      it, so nothing here is served in breach of the upstream's rules.</p>
    </section>
    """
  end

  defp trial_markup do
    """
    <section id="free-trial">
      <h2>Free trial</h2>
      <p>New accounts get <strong>$__CREDIT__ of free credit</strong> &mdash; __CALLS__ tool calls
      &mdash; with no card and no subscription. One command gets you a key:</p>
      <pre><code>curl -X POST __BASE__/v1/signup</code></pre>
      <p>Or <a href="/try">run a call in your browser</a> first; that one is on us.</p>
    </section>

    """
  end

  defp trial_section do
    credit = Settings.trial_credit_micro_usd()

    if credit > 0 do
      calls = credit |> div(Settings.price_micro_usd()) |> delimit()

      trial_markup()
      |> String.replace("__CREDIT__", Billing.format_usd(credit))
      |> String.replace("__CALLS__", calls)
      |> String.replace("__BASE__", Settings.canonical_base_url())
    else
      ""
    end
  end

  defp delimit(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp pricing_section(price) do
    """
    <section id="pricing">
      <h2>MCP gateway pricing</h2>
      <p><strong>$#{price} per tool call.</strong> No subscription, no monthly minimum, no seat
      licence. Discovery is free: listing tools, reading this documentation and querying the
      registry never cost anything. You are charged only when a call reaches an upstream provider
      and comes back with a result, and a call that fails in transit is refunded automatically
      inside the same request.</p>
      <p>Billing is prepaid credits drawn down per call, tracked in whole micro-dollars
      (1 &micro;USD = $0.000001) in an append-only ledger, so nothing is rounded away. A call your
      balance cannot cover is refused with HTTP 402 <em>before</em> any provider is contacted.</p>
      <table>
        <caption>How per-call pricing compares</caption>
        <thead><tr><th>Model</th><th>Typical cost</th><th>Commitment</th></tr></thead>
        <tbody>
          <tr><th scope="row">This gateway</th><td>$#{price} per call</td><td>None, prepaid credits</td></tr>
          <tr><th scope="row">Subscription MCP servers</th><td>$19&ndash;$149 per month</td><td>Monthly, per server</td></tr>
          <tr><th scope="row">Self-hosting</th><td>Your own infrastructure</td><td>Run and update each server</td></tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp connect_section(base) do
    """
    <section id="connect">
      <h2>How to connect</h2>
      <p>The gateway speaks MCP over Streamable HTTP and supports both the stateless
      #{hd(P.modern_versions())} revision and the older <code>initialize</code> handshake, so
      current and older clients both work.</p>
      <pre><code>POST #{base}/mcp
    Authorization: Bearer &lt;your gateway API key&gt;
    Content-Type: application/json
    Accept: application/json, text/event-stream
    MCP-Protocol-Version: #{hd(P.modern_versions())}</code></pre>
      <p>Point a client at <code>#{base}/mcp</code> for every tool, or at
      <code>#{base}/mcp/&lt;server&gt;</code> to narrow it to one provider. The full connection,
      billing and error-handling contract is in <a href="/agent.txt">agent.txt</a>, written for an
      agent to read unaided.</p>
    </section>
    """
  end

  defp catalog_section(servers, base) do
    rows =
      Enum.map_join(servers, "\n", fn s ->
        """
        <li>
          <h3><a href="/docs/servers/#{s.slug}">#{esc(s.title || s.slug)}</a></h3>
          <p>#{esc(s.description)}</p>
          <p class="meta">#{length(s.tools)} tools &middot; <code>#{esc(s.name)}</code></p>
        </li>
        """
      end)

    """
    <section id="catalog">
      <h2>MCP servers in this gateway</h2>
      <p>Every entry below is live right now. The list is generated from the catalog on each
      request, so a provider that has been delisted disappears from this page at the same moment
      it stops being routable. Providers are ordered by the headroom their terms give us, so the
      ones at the top are the ones to lean on.</p>
      <ul class="catalog">
      #{rows}
      </ul>
      <p>The same catalog is served as a standard
      <a href="#{base}/v0.1/servers">MCP Registry API</a>, so other registries and clients can
      consume it with ordinary tooling.</p>
    </section>
    """
  end

  defp compliance_section do
    """
    <section id="compliance">
      <h2>Every provider's terms are checked first</h2>
      <p>An API is listed here only if its terms permit commercial use <em>and</em> permit us to
      call it on behalf of paying third parties. That rules a lot out: several of the best-known
      &ldquo;open&rdquo; APIs explicitly forbid this model &mdash; some require every end user to
      hold their own key, others name API resellers as prohibited, and several free tiers are
      licensed for non-commercial use only. Open content does not imply an open pipe.</p>
      <p>Where terms permit part of an API but not the rest, the individual tools are excluded
      rather than the whole server. Each entry records the terms URL, the date we checked and the
      decisive clauses, and a verdict that goes stale is delisted automatically rather than being
      served on an assumption.</p>
      <p>The verdict for every provider we evaluated, including the ones we rejected and why, is
      published on each provider's page above and in the project's
      <a href="https://github.com/lbesecker195/mcp-gateway/blob/main/catalog/COMPLIANCE.md">compliance
      record</a>.</p>
    </section>
    """
  end

  defp agents_section(base) do
    """
    <section id="for-agents">
      <h2>For agents and crawlers</h2>
      <ul class="links">
        <li><a href="/llms.txt">llms.txt</a> &mdash; machine-readable index of the gateway and every server</li>
        <li><a href="/llms-full.txt">llms-full.txt</a> &mdash; the same with every tool and its parameters inlined</li>
        <li><a href="/agent.txt">agent.txt</a> &mdash; connect, authenticate, pay, retry and handle errors</li>
        <li><a href="/skill.txt">skill.txt</a> &mdash; task recipes that chain tools, with the cost of each</li>
        <li><a href="/server.json">server.json</a> &mdash; this gateway's own MCP registry entry</li>
        <li><a href="#{base}/v0.1/servers">/v0.1/servers</a> &mdash; MCP Registry API over the catalog</li>
      </ul>
    </section>
    """
  end

  defp footer(base) do
    """
    <footer>
      <p><a href="#{base}/health">Status</a> &middot;
      <a href="https://github.com/lbesecker195/mcp-gateway">Source</a> &middot;
      <a href="https://ai.mcpharbor.dev">MCP Registry</a></p>
      <p class="fine">Apache-2.0. Data belongs to the providers listed above and is served under
      their terms; attribution requirements are reproduced on each server's page.</p>
    </footer>
    """
  end

  ## ------------------------------------------------------------------ head

  # `escape: :html_safe` is a security control, not formatting: this JSON sits inside a
  # <script> element, and without it a catalog title containing "</script>" would close
  # the element and inject markup into the page.
  defp jsonld(servers, tools, base, price) do
    Jason.encode!(
      %{
        "@context" => "https://schema.org",
        "@type" => "WebAPI",
        "name" => "MCP Gateway",
        "alternateName" => "Model Context Protocol Gateway",
        "description" => @description,
        "url" => "#{base}/",
        "documentation" => "#{base}/agent.txt",
        "termsOfService" => "#{base}/agent.txt",
        "provider" => %{
          "@type" => "Organization",
          "name" => "mcpharbor",
          "url" => "https://ai.mcpharbor.dev"
        },
        "offers" => %{
          "@type" => "Offer",
          "price" => price,
          "priceCurrency" => "USD",
          "description" => "Per tool call. No subscription.",
          "eligibleQuantity" => %{
            "@type" => "QuantitativeValue",
            "value" => 1,
            "unitText" => "tool call"
          }
        },
        "potentialAction" => %{
          "@type" => "SearchAction",
          "target" => "#{base}/v0.1/servers?search={search_term_string}",
          "query-input" => "required name=search_term_string"
        },
        "about" => Enum.map(servers, &(&1.title || &1.slug)),
        "totalItems" => tools
      },
      escape: :html_safe
    )
  end

  defp css do
    """
    :root{--bg:#fff;--fg:#16181d;--muted:#5b6270;--line:#e3e6ec;--accent:#1c5fd6;--card:#f7f8fa}
    @media(prefers-color-scheme:dark){
      :root{--bg:#0f1115;--fg:#e8eaee;--muted:#a0a7b4;--line:#262b34;--accent:#7aa7ff;--card:#161a21}
    }
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--fg);
      font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
    main,footer{max-width:52rem;margin:0 auto;padding:0 1.25rem}
    header{padding:3.5rem 0 2rem}
    h1{font-size:clamp(2.2rem,6vw,3.2rem);line-height:1.1;margin:0 0 .75rem;letter-spacing:-.02em}
    h2{font-size:1.5rem;margin:2.75rem 0 .75rem;letter-spacing:-.01em}
    h3{font-size:1.05rem;margin:0 0 .25rem}
    .lede{font-size:1.2rem;color:var(--muted);margin:0 0 1.5rem;max-width:40rem}
    .cta{display:flex;gap:.6rem;flex-wrap:wrap;margin:0 0 2rem}
    .btn{display:inline-block;padding:.6rem 1.1rem;border-radius:.5rem;background:var(--accent);
      color:#fff;text-decoration:none;font-weight:600}
    .btn.secondary{background:transparent;color:var(--accent);border:1px solid var(--line)}
    .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(7.5rem,1fr));gap:.75rem;margin:0;
      padding:1rem;background:var(--card);border:1px solid var(--line);border-radius:.6rem}
    .stats div{margin:0}
    .stats dt{font-size:.75rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}
    .stats dd{margin:.15rem 0 0;font-size:1.35rem;font-weight:650}
    a{color:var(--accent)}
    section{border-top:1px solid var(--line);padding-top:.5rem}
    p{max-width:42rem}
    code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em;
      background:var(--card);padding:.12em .35em;border-radius:.25rem}
    pre{background:var(--card);border:1px solid var(--line);border-radius:.6rem;padding:1rem;
      overflow-x:auto}
    pre code{background:none;padding:0;font-size:.85rem;line-height:1.5}
    table{border-collapse:collapse;width:100%;margin:1rem 0;font-size:.95rem}
    caption{text-align:left;color:var(--muted);font-size:.85rem;padding-bottom:.5rem}
    th,td{text-align:left;padding:.6rem .5rem;border-bottom:1px solid var(--line)}
    thead th{font-size:.78rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}
    ul.catalog{list-style:none;padding:0;display:grid;
      grid-template-columns:repeat(auto-fill,minmax(15rem,1fr));gap:.85rem}
    ul.catalog li{background:var(--card);border:1px solid var(--line);border-radius:.6rem;padding:.9rem}
    ul.catalog p{margin:.25rem 0;font-size:.9rem;color:var(--muted)}
    ul.catalog .meta{font-size:.78rem}
    ul.catalog code{font-size:.78em;background:none;padding:0}
    ul.links{padding-left:1.1rem}
    ul.links li{margin:.3rem 0}
    footer{border-top:1px solid var(--line);margin-top:3rem;padding-top:1.25rem;padding-bottom:3rem;
      color:var(--muted);font-size:.9rem}
    .fine{font-size:.82rem}
    """
  end

  # Catalog text is ours, but it is still user-visible output built by interpolation, so it is
  # escaped rather than trusted.
  defp esc(nil), do: ""

  defp esc(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp esc(value), do: value |> to_string() |> esc()
end
