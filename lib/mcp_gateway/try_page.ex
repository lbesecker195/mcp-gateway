defmodule McpGateway.TryPage do
  @moduledoc """
  The `/try` page: how to add this gateway to an AI agent, and what you say to it afterwards.

  The point of the page is that setup is the only technical step. Once the gateway is
  connected, the agent discovers the tools itself and the user goes back to typing ordinary
  sentences — so the page leads with the conversation and treats the config as the footnote it
  should be.

  Every snippet below was checked against that client's own official documentation, and the
  per-client warnings are the ones that actually bite: the field names differ between clients
  (`servers` vs `mcpServers`, `url` vs `serverUrl`, `type` vs `transport`), and a plausible
  snippet with the wrong one fails in a way that looks like our gateway is broken.

  The transcripts are illustrative and say so. They are not recordings, and nothing on this
  page makes a live call.
  """

  alias McpGateway.{Billing, Settings}

  def html do
    base = Settings.canonical_base_url()
    price = Billing.format_usd(Settings.price_micro_usd())
    credit = Settings.trial_credit_micro_usd()

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Set up the MCP Gateway in Claude, Cursor, VS Code and more</title>
    <meta name="description" content="Add one Model Context Protocol endpoint to Claude Code, Claude Desktop, Cursor, VS Code, Windsurf or the OpenAI Agents SDK, then just ask your agent in plain language.">
    <link rel="canonical" href="#{base}/try">
    <meta property="og:title" content="Set up the MCP Gateway in your AI agent">
    <meta property="og:description" content="One endpoint, six clients, then plain language. Verified setup for each.">
    <style>#{css()}</style>
    </head>
    <body>
    <main>
      <p class="back"><a href="/">&larr; MCP Gateway</a></p>
      <h1>Add it to your agent, then just ask</h1>
      <p class="lede">Connecting the gateway is one config change. After that your agent
      discovers #{tool_phrase()} by itself and you go back to typing ordinary sentences.</p>

      #{chat_section(base)}
      #{setup_section(base)}
      #{after_section(price, credit)}
    </main>
    <footer>
      <p><a href="/">Home</a> &middot; <a href="/agent.txt">agent.txt</a> &middot;
      <a href="/llms.txt">Every tool</a> &middot;
      <a href="https://github.com/lbesecker195/mcp-gateway">Source</a></p>
    </footer>
    <script>#{js()}</script>
    </body>
    </html>
    """
  end

  defp tool_phrase do
    case McpGateway.Catalog.list_servers_with_tools() do
      [] -> "the catalog"
      servers -> "#{servers |> Enum.map(&length(&1.tools)) |> Enum.sum()} tools"
    end
  end

  ## ------------------------------------------------------------------ the conversation

  defp chat_section(base) do
    """
    <section id="conversation">
      <h2>What it looks like</h2>
      <p>Two things people actually type once the gateway is connected. The first has the agent
      onboard itself: <a href="/agent.txt">agent.txt</a> documents the signup call, so the agent
      can read it and claim the free credit without you leaving the chat.</p>

      <div class="chat">
        <div class="msg user">Read #{base}/agent.txt and sign up for the free trial.</div>
        <div class="msg bot">
          <p>Reading <code>agent.txt</code>&hellip; it documents a signup endpoint.</p>
          <p class="act">POST #{base}/v1/signup</p>
          <p>Done. You have <strong>$10.00 of credit</strong>, about 100,000 tool calls. I have
          saved the key. Discovery is free; each tool call costs $0.0001.</p>
        </div>

        <div class="msg user">What does the express package depend on?</div>
        <div class="msg bot">
          <p class="act">npm_registry__npm_deps &nbsp;<span class="cost">$0.0001</span></p>
          <p>express v5.2.1 has 28 dependencies, including <code>qs</code>, <code>send</code>,
          <code>cookie</code>, <code>debug</code> and <code>etag</code>.</p>
        </div>

        <div class="msg user">Find recent research on the Model Context Protocol.</div>
        <div class="msg bot">
          <p class="act">openalex__openalex_search_entities &nbsp;<span class="cost">$0.0001</span></p>
          <p>2,600,858 works match. The most cited recent one is <em>Model Context Protocol
          (MCP): Landscape, Security Threats, and Future Research Directions</em> (2026).</p>
        </div>
      </div>
      <p class="disclosure">Illustrative, not a recording. Your agent picks the tool; the gateway
      routes it and bills the call.</p>
    </section>
    """
  end

  ## ------------------------------------------------------------------ setup

  defp setup_section(base) do
    clients = clients(base)

    tabs =
      Enum.map_join(Enum.with_index(clients), "\n", fn {c, i} ->
        ~s(<button class="tab#{if i == 0, do: " on"}" data-tab="#{c.id}">#{esc(c.name)}</button>)
      end)

    panels =
      Enum.map_join(Enum.with_index(clients), "\n", fn {c, i} ->
        """
        <div class="panel#{if i == 0, do: " on"}" id="panel-#{c.id}">
          <p class="where">#{c.where}</p>
          <pre><code>#{esc(c.snippet)}</code></pre>
          #{if c.warning, do: ~s(<p class="warn"><strong>Watch out:</strong> #{c.warning}</p>), else: ""}
          <p class="src">Verified against <a href="#{c.source}" rel="nofollow noopener">#{esc(c.source_label)}</a>.</p>
        </div>
        """
      end)

    """
    <section id="setup">
      <h2>Setup, once</h2>
      <p>Replace <code>YOUR_KEY</code> with your API key. Field names differ between clients
      &mdash; <code>servers</code> against <code>mcpServers</code>, <code>url</code> against
      <code>serverUrl</code> &mdash; and the wrong one fails in a way that looks like the gateway
      is down, so each snippet below is the one that client's own docs specify.</p>
      <div class="tabs">#{tabs}</div>
      #{panels}
    </section>
    """
  end

  defp clients(base) do
    url = "#{base}/mcp"

    [
      %{
        id: "claude-code",
        name: "Claude Code",
        where: "Run this in your terminal. No file to edit.",
        snippet: """
        claude mcp add --transport http --scope user mcpharbor \\
          #{url} \\
          --header "Authorization: Bearer YOUR_KEY"

        claude mcp list          # confirm it connected
        """,
        warning:
          "This puts your key in shell history. To avoid that, add it to a project " <>
            "<code>.mcp.json</code> instead and reference an environment variable: the JSON field " <>
            "is <code>\"type\": \"http\"</code>, not <code>transport</code>, and an entry with a " <>
            "<code>url</code> but no <code>type</code> is read as a stdio server and skipped.",
        source: "https://code.claude.com/docs/en/mcp",
        source_label: "Claude Code MCP docs"
      },
      %{
        id: "claude-desktop",
        name: "Claude Desktop",
        where: "Settings → Connectors → Add custom connector.",
        snippet: """
        Name:            MCP Harbor
        MCP server URL:  #{url}
        Authentication:  No sign-in
        Request headers:
          authorization  ->  Bearer YOUR_KEY
        """,
        warning:
          "Choose <strong>No sign-in</strong>; on an OAuth connection Claude owns the " <>
            "Authorization header and you cannot set it. Type the word <code>Bearer</code> and a " <>
            "space before your key &mdash; the value is sent verbatim. Authentication cannot be " <>
            "edited after the connector is added, so rotating the key means removing and re-adding " <>
            "it. If your dialog has no <em>Request headers</em> section, your organization does not " <>
            "have that beta yet; use the <code>mcp-remote</code> bridge instead.",
        source: "https://claude.com/docs/connectors/custom/remote-mcp",
        source_label: "Anthropic custom connector docs"
      },
      %{
        id: "cursor",
        name: "Cursor",
        where: "~/.cursor/mcp.json for every project, or .cursor/mcp.json for one.",
        snippet: """
        {
          "mcpServers": {
            "mcpharbor": {
              "url": "#{url}",
              "headers": {
                "Authorization": "Bearer YOUR_KEY"
              }
            }
          }
        }
        """,
        warning: nil,
        source: "https://cursor.com/docs/context/mcp",
        source_label: "Cursor MCP docs"
      },
      %{
        id: "vscode",
        name: "VS Code",
        where:
          ".vscode/mcp.json in your project. VS Code prompts for the key and stores it securely.",
        snippet: """
        {
          "inputs": [
            {
              "type": "promptString",
              "id": "mcpharbor-key",
              "description": "MCP Harbor API key",
              "password": true
            }
          ],
          "servers": {
            "mcpharbor": {
              "type": "http",
              "url": "#{url}",
              "headers": {
                "Authorization": "Bearer ${input:mcpharbor-key}"
              }
            }
          }
        }
        """,
        warning:
          "The top-level key is <code>servers</code>, not <code>mcpServers</code> as in most " <>
            "other clients. Use the Start action VS Code shows above the entry, then ask in Copilot " <>
            "Chat in Agent mode. Do not add comments &mdash; this file is plain JSON.",
        source: "https://code.visualstudio.com/docs/agents/reference/mcp-configuration",
        source_label: "VS Code MCP configuration"
      },
      %{
        id: "windsurf",
        name: "Windsurf",
        where: "~/.codeium/windsurf/mcp_config.json",
        snippet: """
        {
          "mcpServers": {
            "mcpharbor": {
              "serverUrl": "#{url}",
              "headers": {
                "Authorization": "Bearer YOUR_KEY"
              }
            }
          }
        }
        """,
        warning:
          "The field is <code>serverUrl</code> here, not <code>url</code>. Cascade also caps " <>
            "itself at 100 tools in total, so a large gateway catalogue can crowd out your other " <>
            "servers &mdash; that shows up as tools quietly missing rather than as an error.",
        source: "https://docs.devin.ai/desktop/cascade/mcp",
        source_label:
          "Cascade MCP docs (published under Devin Desktop since the Windsurf rebrand)"
      },
      %{
        id: "openai",
        name: "OpenAI Agents SDK",
        where: "Python. pip install openai-agents",
        snippet: """
        import asyncio, os
        from agents import Agent, Runner
        from agents.mcp import MCPServerStreamableHttp

        async def main():
            async with MCPServerStreamableHttp(
                name="MCP Harbor",
                params={
                    "url": "#{url}",
                    "headers": {"Authorization": f"Bearer {os.environ['MCPHARBOR_API_KEY']}"},
                    "timeout": 30,
                },
            ) as server:
                agent = Agent(name="Assistant", mcp_servers=[server])
                result = await Runner.run(agent, "What does the express package depend on?")
                print(result.final_output)

        asyncio.run(main())
        """,
        warning:
          "Two keys are needed: <code>MCPHARBOR_API_KEY</code> for the gateway and " <>
            "<code>OPENAI_API_KEY</code> for the model running the agent. Setting only the first " <>
            "gives an authentication error from OpenAI, which looks like our problem but is not. " <>
            "Use <code>MCPServerStreamableHttp</code>, not <code>MCPServerSse</code>.",
        source: "https://openai.github.io/openai-agents-python/mcp/",
        source_label: "OpenAI Agents SDK MCP docs"
      }
    ]
  end

  ## ------------------------------------------------------------------ after

  defp after_section(price, credit) do
    """
    <section id="after">
      <h2>Then what</h2>
      <ul class="plain">
        <li><strong>Ask in plain language.</strong> Your agent reads the tool list and picks for
        itself. You never name a tool.</li>
        <li><strong>Discovery is free.</strong> Listing tools, reading the docs and querying the
        registry never cost anything. Only a tool call that reaches a provider is billed, at
        #{esc("$" <> price)}.</li>
        <li><strong>You start with $#{Billing.format_usd(credit)} of credit</strong> &mdash;
        about #{delimit(div(credit, Settings.price_micro_usd()))} calls. No card.</li>
        <li><strong>A failed call is refunded</strong> automatically, inside the same request.</li>
      </ul>
      <p class="warn">If a client reports the server as unauthorized, check the key has no
      trailing whitespace and that <code>Bearer</code> precedes it. This gateway uses a static
      bearer token and does not use OAuth, so any prompt to sign in means the header is not
      reaching us.</p>
      <p><a class="btn" href="/agent.txt">Read agent.txt</a>
      <a class="btn secondary" href="/llms.txt">Browse every tool</a></p>
    </section>
    """
  end

  ## ------------------------------------------------------------------ assets

  defp js do
    """
    document.querySelectorAll('.tab').forEach(function (t) {
      t.addEventListener('click', function () {
        document.querySelectorAll('.tab').forEach(function (x) { x.classList.remove('on'); });
        document.querySelectorAll('.panel').forEach(function (p) { p.classList.remove('on'); });
        t.classList.add('on');
        var panel = document.getElementById('panel-' + t.dataset.tab);
        if (panel) { panel.classList.add('on'); }
      });
    });
    """
  end

  defp css do
    """
    :root{--bg:#fff;--fg:#16181d;--muted:#5b6270;--line:#e3e6ec;--accent:#1c5fd6;--card:#f7f8fa;--ok:#1a7f4b;--warn:#8a5a00}
    @media(prefers-color-scheme:dark){
      :root{--bg:#0f1115;--fg:#e8eaee;--muted:#a0a7b4;--line:#262b34;--accent:#7aa7ff;--card:#161a21;--ok:#57c98a;--warn:#d9a441}
    }
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--fg);
      font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
    main,footer{max-width:48rem;margin:0 auto;padding:0 1.25rem}
    .back{margin:1.5rem 0 0}.back a{text-decoration:none;color:var(--muted)}
    h1{font-size:clamp(2rem,5vw,2.6rem);margin:.5rem 0;letter-spacing:-.02em}
    h2{font-size:1.4rem;margin:2.5rem 0 .6rem}
    .lede{color:var(--muted);margin:0 0 1.5rem;max-width:36rem}
    a{color:var(--accent)}
    p{max-width:40rem}
    section{border-top:1px solid var(--line);padding-top:.5rem}
    .chat{display:flex;flex-direction:column;gap:.7rem;background:var(--card);
      border:1px solid var(--line);border-radius:.75rem;padding:1rem;margin:1rem 0 .5rem}
    .msg{max-width:90%;padding:.65rem .9rem;border-radius:.7rem;font-size:.94rem}
    .msg p{margin:0 0 .4rem;max-width:none}.msg p:last-child{margin-bottom:0}
    .msg.user{background:var(--accent);color:#fff;align-self:flex-end;font-weight:500}
    .msg.bot{background:var(--bg);border:1px solid var(--line);align-self:flex-start}
    .act{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.8rem;
      color:var(--muted)}
    .cost{color:var(--ok);font-weight:650}
    .disclosure{font-size:.82rem;color:var(--muted)}
    .tabs{display:flex;flex-wrap:wrap;gap:.4rem;margin:1rem 0 .8rem}
    .tab{font:inherit;font-size:.88rem;padding:.4rem .8rem;border-radius:2rem;cursor:pointer;
      background:var(--bg);color:var(--fg);border:1px solid var(--line)}
    .tab:hover{border-color:var(--accent)}
    .tab.on{background:var(--accent);color:#fff;border-color:var(--accent)}
    .panel{display:none}.panel.on{display:block}
    .where{font-size:.88rem;color:var(--muted);margin:0 0 .5rem}
    .warn{font-size:.88rem;background:var(--card);border-left:3px solid var(--warn);
      padding:.6rem .8rem;border-radius:.3rem;margin:.8rem 0}
    .src{font-size:.8rem;color:var(--muted)}
    pre{background:var(--card);border:1px solid var(--line);border-radius:.6rem;padding:.9rem;
      overflow-x:auto;margin:0}
    pre code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.82rem;line-height:1.55}
    code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em}
    .msg code,.warn code{background:rgba(127,127,127,.15);padding:.1em .3em;border-radius:.25rem}
    ul.plain{padding-left:1.1rem}ul.plain li{margin:.45rem 0;max-width:40rem}
    .btn{display:inline-block;padding:.55rem 1.05rem;border-radius:.5rem;background:var(--accent);
      color:#fff;text-decoration:none;font-weight:600;margin-right:.4rem}
    .btn.secondary{background:transparent;color:var(--accent);border:1px solid var(--line)}
    footer{border-top:1px solid var(--line);margin-top:3rem;padding-top:1.25rem;padding-bottom:3rem;
      color:var(--muted);font-size:.9rem}
    """
  end

  defp delimit(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

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
