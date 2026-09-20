defmodule McpGateway.TryPage do
  @moduledoc """
  The `/try` page: a chat-styled demo that makes real, billed calls through the real gateway.

  It is deliberately a *guided* demo, and says so on the page. The example questions map to
  fixed tool calls rather than being interpreted by a language model, because pretending an LLM
  were choosing the tool would misrepresent what the visitor is seeing. What is real is the
  part that matters: the call goes through the same metering, the same compliance gate and the
  same upstream as a paying customer's, and the page shows the actual charge.

  The credit is the gateway's own, bounded to a daily budget by `McpGateway.Demo`.
  """

  alias McpGateway.{Billing, Demo, Settings}

  def html do
    base = Settings.canonical_base_url()
    price = Billing.format_usd(Settings.price_micro_usd())
    credit = Settings.trial_credit_micro_usd()
    credit_usd = Billing.format_usd(credit)
    calls = credit |> div(Settings.price_micro_usd()) |> delimit()
    examples = Demo.examples()

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Try the MCP Gateway — a live tool call in your browser</title>
    <meta name="description" content="Run a real Model Context Protocol tool call in your browser, see what it returns and what it costs, then get $#{credit_usd} of free credit.">
    <link rel="canonical" href="#{base}/try">
    <meta property="og:title" content="Try the MCP Gateway">
    <meta property="og:description" content="Run a live MCP tool call in your browser and see exactly what it costs.">
    <style>#{css()}</style>
    </head>
    <body>
    <main>
      <p class="back"><a href="/">&larr; MCP Gateway</a></p>
      <h1>Try it</h1>
      <p class="lede">Pick a question. It runs a real tool call through this gateway &mdash; same
      metering, same providers, same #{esc(price)} per call as a paying client &mdash; and shows
      you exactly what came back and what it cost.</p>

      <section class="chat" id="chat" aria-live="polite">
        <div class="msg bot">
          <p>Ask me something. I'll call a real provider and show you the bill.</p>
        </div>
      </section>

      #{if examples == [], do: unavailable(), else: composer(examples)}

      <p class="disclosure">A guided demo: each question maps to a fixed tool call rather than
      being interpreted by a language model. The call itself is real and really billed &mdash; to
      our account, not yours.</p>

      <section id="get-started">
        <h2>Get started in three steps</h2>
        <p>You get <strong>$#{credit_usd} of free credit</strong> &mdash; #{calls} tool calls &mdash;
        with no card and no subscription.</p>
        <ol class="steps">
          <li>
            <h3>1. Get a key</h3>
            <pre><code>curl -X POST #{base}/v1/signup</code></pre>
            <p>Returns an API key and your free credit. The key is shown once.</p>
          </li>
          <li>
            <h3>2. Point your client at the gateway</h3>
            <pre><code>{
      "mcpServers": {
        "gateway": {
          "type": "streamable-http",
          "url": "#{base}/mcp",
          "headers": { "Authorization": "Bearer YOUR_KEY" }
        }
      }
    }</code></pre>
            <p>Any MCP client works. Use <code>#{base}/mcp/&lt;server&gt;</code> for one provider.</p>
          </li>
          <li>
            <h3>3. Call a tool</h3>
            <pre><code>curl -X POST #{base}/mcp \\
      -H "Authorization: Bearer YOUR_KEY" \\
      -H "Content-Type: application/json" \\
      -H "MCP-Protocol-Version: 2026-07-28" \\
      -H "Mcp-Method: tools/list" \\
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list",
           "params":{"_meta":{
             "io.modelcontextprotocol/protocolVersion":"2026-07-28",
             "io.modelcontextprotocol/clientCapabilities":{}}}}'</code></pre>
            <p>Listing tools is free. You are charged #{esc(price)} only when a
            <code>tools/call</code> reaches a provider and returns a result.</p>
          </li>
        </ol>
        <p><a class="btn" href="/agent.txt">Read agent.txt</a>
        <a class="btn secondary" href="/llms.txt">Browse every tool</a></p>
      </section>
    </main>
    <footer>
      <p><a href="/">Home</a> &middot; <a href="/v0.1/servers">Catalog API</a> &middot;
      <a href="https://github.com/lbesecker195/mcp-gateway">Source</a></p>
    </footer>
    <script>#{js()}</script>
    </body>
    </html>
    """
  end

  defp composer(examples) do
    chips =
      Enum.map_join(examples, "\n", fn ex ->
        ~s(<button class="chip" data-example="#{esc(ex.id)}" data-editable="#{esc(ex.editable)}") <>
          ~s( data-default="#{esc(ex.args[ex.editable])}">#{esc(ex.question)}</button>)
      end)

    """
    <div class="composer">
      <p class="hint">Pick one:</p>
      <div class="chips">#{chips}</div>
      <div class="editrow" id="editrow" hidden>
        <input id="query" type="text" maxlength="120" autocomplete="off"
               aria-label="Search terms for this call">
        <button id="send" class="btn">Run it</button>
      </div>
    </div>
    """
  end

  defp unavailable do
    """
    <div class="composer">
      <p class="hint">The demo providers are not routable at the moment. The
      <a href="/v0.1/servers">catalog</a> shows what is live.</p>
    </div>
    """
  end

  defp js do
    """
    (function () {
      var chat = document.getElementById('chat');
      var editrow = document.getElementById('editrow');
      var input = document.getElementById('query');
      var send = document.getElementById('send');
      var current = null;
      var busy = false;

      function el(cls, html) {
        var d = document.createElement('div');
        d.className = cls;
        d.innerHTML = html;
        chat.appendChild(d);
        chat.scrollTop = chat.scrollHeight;
        return d;
      }
      function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, function (c) {
          return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
      }

      document.querySelectorAll('.chip').forEach(function (chip) {
        chip.addEventListener('click', function () {
          current = chip.dataset.example;
          document.querySelectorAll('.chip').forEach(function (c) { c.classList.remove('on'); });
          chip.classList.add('on');
          if (chip.dataset.editable && chip.dataset.editable !== '') {
            editrow.hidden = false;
            input.value = chip.dataset.default || '';
            input.focus();
          } else {
            editrow.hidden = true;
            run(chip.textContent);
          }
        });
      });

      if (send) { send.addEventListener('click', function () { run(input.value); }); }
      if (input) {
        input.addEventListener('keydown', function (e) { if (e.key === 'Enter') run(input.value); });
      }

      function run(label) {
        if (busy || !current) { return; }
        busy = true;
        el('msg user', '<p>' + escapeHtml(label) + '</p>');
        var thinking = el('msg bot', '<p class="dots">Calling the provider&hellip;</p>');

        fetch('/try/call', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ example: current, query: input ? input.value : null })
        })
          .then(function (r) { return r.json(); })
          .then(function (d) {
            thinking.remove();
            if (!d.ok) {
              el('msg bot error', '<p>' + escapeHtml(d.message || 'That did not work.') + '</p>');
              return;
            }
            var meta =
              '<p class="callmeta"><code>' + escapeHtml(d.tool) + '</code>' +
              '<span class="cost">charged $' + escapeHtml(d.chargedUsd) + '</span></p>';
            el('msg bot', meta + '<pre>' + escapeHtml(d.text || '(no text returned)') + '</pre>');
          })
          .catch(function () {
            thinking.remove();
            el('msg bot error', '<p>The demo could not be reached.</p>');
          })
          .finally(function () { busy = false; });
      }
    })();
    """
  end

  defp css do
    """
    :root{--bg:#fff;--fg:#16181d;--muted:#5b6270;--line:#e3e6ec;--accent:#1c5fd6;--card:#f7f8fa;--ok:#1a7f4b}
    @media(prefers-color-scheme:dark){
      :root{--bg:#0f1115;--fg:#e8eaee;--muted:#a0a7b4;--line:#262b34;--accent:#7aa7ff;--card:#161a21;--ok:#57c98a}
    }
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--fg);
      font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
    main,footer{max-width:46rem;margin:0 auto;padding:0 1.25rem}
    .back{margin:1.5rem 0 0}.back a{text-decoration:none;color:var(--muted)}
    h1{font-size:clamp(2rem,5vw,2.6rem);margin:.5rem 0 .5rem;letter-spacing:-.02em}
    h2{font-size:1.4rem;margin:2.5rem 0 .5rem}
    h3{font-size:1rem;margin:0 0 .4rem}
    .lede{color:var(--muted);margin:0 0 1.5rem}
    a{color:var(--accent)}
    .chat{background:var(--card);border:1px solid var(--line);border-radius:.75rem;padding:1rem;
      min-height:11rem;max-height:26rem;overflow-y:auto;display:flex;flex-direction:column;gap:.7rem}
    .msg{max-width:88%;padding:.6rem .85rem;border-radius:.7rem;font-size:.94rem}
    .msg p{margin:0}
    .msg.bot{background:var(--bg);border:1px solid var(--line);align-self:flex-start}
    .msg.user{background:var(--accent);color:#fff;align-self:flex-end}
    .msg.error{border-color:#c2410c}
    .msg pre{margin:.5rem 0 0;white-space:pre-wrap;word-break:break-word;font-size:.82rem;
      max-height:15rem;overflow-y:auto;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
    .callmeta{display:flex;justify-content:space-between;align-items:center;gap:.5rem;
      font-size:.78rem;color:var(--muted);flex-wrap:wrap}
    .callmeta code{font-size:.9em}
    .cost{color:var(--ok);font-weight:650;white-space:nowrap}
    .dots{color:var(--muted)}
    .composer{margin:1rem 0 .5rem}
    .hint{font-size:.85rem;color:var(--muted);margin:0 0 .5rem}
    .chips{display:flex;flex-wrap:wrap;gap:.5rem}
    .chip{font:inherit;font-size:.88rem;padding:.45rem .8rem;border-radius:2rem;cursor:pointer;
      background:var(--bg);color:var(--fg);border:1px solid var(--line)}
    .chip:hover{border-color:var(--accent)}
    .chip.on{border-color:var(--accent);color:var(--accent)}
    .editrow{display:flex;gap:.5rem;margin-top:.7rem}
    .editrow input{flex:1;font:inherit;padding:.5rem .7rem;border-radius:.5rem;
      border:1px solid var(--line);background:var(--bg);color:var(--fg)}
    .btn{display:inline-block;font:inherit;padding:.5rem 1rem;border-radius:.5rem;border:0;
      background:var(--accent);color:#fff;text-decoration:none;font-weight:600;cursor:pointer}
    .btn.secondary{background:transparent;color:var(--accent);border:1px solid var(--line)}
    .disclosure{font-size:.82rem;color:var(--muted);margin:.75rem 0 0}
    .steps{list-style:none;padding:0;counter-reset:s}
    .steps li{margin:1.25rem 0;padding:1rem;background:var(--card);border:1px solid var(--line);
      border-radius:.6rem}
    .steps p{margin:.5rem 0 0;font-size:.9rem;color:var(--muted)}
    pre{background:var(--bg);border:1px solid var(--line);border-radius:.5rem;padding:.8rem;
      overflow-x:auto;margin:0}
    pre code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.8rem;line-height:1.5}
    code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em}
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
