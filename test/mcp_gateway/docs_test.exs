defmodule McpGateway.DocsTest do
  use McpGateway.DataCase, async: true

  alias McpGateway.Billing
  alias McpGateway.Catalog
  alias McpGateway.Docs
  alias McpGateway.Fixtures
  alias McpGateway.Gateway
  alias McpGateway.MCP.Protocol, as: P
  alias McpGateway.Settings

  # An upstream whose command, argument and environment value must never reach a document.
  @leaky_upstream %{
    "type" => "stdio",
    "command" => "npx",
    "args" => ["--launch-secret-arg", "@vendor/secret-upstream@9.9.9"],
    "env" => %{"UPSTREAM_API_KEY" => "sk-do-not-leak-12345"}
  }

  @never_routable ["NEVERLISTED", "notallowed", "staleterms"]

  @never_exposed [
    "npx",
    "--launch-secret-arg",
    "@vendor/secret-upstream",
    "UPSTREAM_API_KEY",
    "sk-do-not-leak-12345",
    "fake_upstream.exs"
  ]

  defp price, do: Settings.price_micro_usd()
  defp usd(micro), do: "$" <> Billing.format_usd(micro)

  # A tool page's "Tool definition" section reproduces the upstream's own JSON verbatim, inside a
  # code fence, which is the point of it. Everything above that heading is prose we wrote, and
  # that is where markdown escaping has to hold.
  defp prose(doc), do: doc |> String.split("## Tool definition") |> hd()

  defp catalog(_context) do
    weatherly =
      Fixtures.insert_server(%{
        slug: "weatherly",
        title: "Weatherly",
        description: "Forecasts and severe-weather alerts for any city.",
        website_url: "https://weatherly.example.com",
        rate_limit: %{"requests" => 20, "window_ms" => 60_000},
        compliance: %{
          "verdict" => "allowed",
          "terms_url" => "https://weatherly.example.com/terms",
          "api_docs_url" => "https://weatherly.example.com/api",
          "checked_on" => Date.to_iso8601(Date.utc_today()),
          "key_required" => "none",
          "attribution" =>
            "Weather data by Weatherly, used under the Weatherly Open Data Licence.",
          "notes" => "Free tier permits proxying and charging for access."
        }
      })

    Fixtures.insert_tool(weatherly, "forecast", %{
      description: "Return a three-day forecast for a city.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "city" => %{"type" => "string", "description" => "City name, for example Oslo."},
          "units" => %{
            "type" => "string",
            "enum" => ["metric", "imperial"],
            "default" => "metric"
          }
        },
        "required" => ["city"]
      }
    })

    Fixtures.insert_tool(weatherly, "alerts", %{description: "List active severe-weather alerts."})

    toolbox =
      Fixtures.insert_fake_server(%{
        slug: "toolbox",
        title: "Toolbox",
        description: "Assorted utility tools.",
        upstream: @leaky_upstream
      })

    denied =
      Fixtures.insert_fake_server(%{
        slug: "notallowed",
        title: "NEVERLISTED Forbidden",
        description: "NEVERLISTED: the provider's terms forbid proxying.",
        compliance_verdict: "not_allowed"
      })

    stale =
      Fixtures.insert_fake_server(%{
        slug: "staleterms",
        title: "NEVERLISTED Expired",
        description: "NEVERLISTED: the verdict is too old to trust.",
        compliance_checked_on: Date.add(Date.utc_today(), -400)
      })

    %{weatherly: weatherly, toolbox: toolbox, denied: denied, stale: stale}
  end

  # Every document the gateway publishes, as strings, for the properties that must hold of all
  # of them at once.
  defp all_documents do
    {:ok, weatherly_doc} = Docs.server_doc("weatherly")
    {:ok, toolbox_doc} = Docs.server_doc("toolbox")
    {:ok, forecast_doc} = Docs.tool_doc("weatherly__forecast")
    {:ok, echo_doc} = Docs.tool_doc("toolbox__echo")

    %{
      "llms.txt" => Docs.llms_txt(),
      "llms-full.txt" => Docs.llms_full_txt(),
      "agent.txt" => Docs.agent_txt(),
      "skill.txt" => Docs.skill_txt(),
      "server.json" => Jason.encode!(Docs.server_json()),
      "/docs/servers/weatherly" => weatherly_doc,
      "/docs/servers/toolbox" => toolbox_doc,
      "/docs/tools/weatherly__forecast" => forecast_doc,
      "/docs/tools/toolbox__echo" => echo_doc
    }
  end

  describe "with a realistic catalog" do
    setup :catalog

    test "llms.txt is an index: title, summary, how to connect, one link per server" do
      base = Settings.base_url()
      llms = Docs.llms_txt()

      assert String.starts_with?(llms, "# ")
      assert llms =~ "\n> "
      assert llms =~ "## Servers"
      assert llms =~ "[Weatherly](#{base}/docs/servers/weatherly)"
      assert llms =~ "[Toolbox](#{base}/docs/servers/toolbox)"
      assert llms =~ "`#{base}/mcp`"
      assert llms =~ "Authorization: Bearer <your gateway API key>"
      assert llms =~ usd(price())

      # An index, not the full reference: it must not inline the tools.
      refute llms =~ "### `weatherly__forecast`"
      assert String.length(llms) < String.length(Docs.llms_full_txt())
    end

    test "llms-full.txt inlines every tool with parameters, price, provider and attribution" do
      full = Docs.llms_full_txt()

      assert full =~ "### `weatherly__forecast`"
      assert full =~ "### `weatherly__alerts`"
      assert full =~ "### `toolbox__echo`"
      assert full =~ "Return a three-day forecast for a city."
      assert full =~ "- `city` (string, required): City name, for example Oslo."

      assert full =~
               "- `units` (string, optional): One of: `metric`, `imperial`. Default: `metric`."

      assert full =~ "- Price: #{usd(price())} (#{price()} micro-USD) per call."
      assert full =~ "<https://weatherly.example.com/terms>"
      assert full =~ "Attribution: Weather data by Weatherly"
      # Toolbox's provider asks for none, and the file says so rather than staying silent.
      assert full =~ "Attribution: not required by this provider."
    end

    test "agent.txt states the endpoint, versions, auth, what is free and what a call costs" do
      base = Settings.base_url()
      agent = Docs.agent_txt()

      assert agent =~ "POST #{base}/mcp"
      assert agent =~ "Authorization: Bearer <your gateway API key>"

      for version <- P.modern_versions() ++ P.legacy_versions() do
        assert agent =~ version
      end

      assert agent =~ P.meta_version_key()
      assert agent =~ P.meta_client_caps_key()

      assert agent =~ "tools/call, and only tools/call"
      assert agent =~ "server/discover"
      assert agent =~ "tools/list"

      assert agent =~ "#{price()} micro-USD per tool call = #{usd(price())} USD."
      assert agent =~ "prepaid credits"
    end

    test "agent.txt quotes exactly the price Billing formats from Settings" do
      agent = Docs.agent_txt()

      assert agent =~ "$" <> Billing.format_usd(Settings.price_micro_usd())
      refute agent =~ "$0.01"
    end

    test "agent.txt explains 402, 429 with Retry-After, and automatic refunds" do
      agent = Docs.agent_txt()

      assert agent =~ "402 PAYMENT REQUIRED"
      assert agent =~ "balance cannot cover this call"
      assert agent =~ "top the account up"
      assert agent =~ "no upstream was contacted"

      assert agent =~ "429 TOO MANY REQUESTS"
      assert agent =~ "Retry-After"
      assert agent =~ "The call was not charged."

      assert agent =~ "refunded to your balance automatically"
      assert agent =~ "idempotent"
    end

    test "agent.txt's worked example is a correct modern tools/call on a real catalog tool" do
      agent = Docs.agent_txt()

      assert [_, named] = Regex.run(~r/^Mcp-Name: (\S+)$/m, agent)
      assert {:ok, _tool, _server} = Catalog.fetch_tool(named)

      assert agent =~ "MCP-Protocol-Version: #{hd(P.modern_versions())}"
      assert agent =~ "Mcp-Method: tools/call"
      assert agent =~ "Accept: application/json, text/event-stream"
      assert agent =~ ~s("method": "tools/call")
      assert agent =~ ~s("name": "#{named}")
      assert agent =~ ~s("#{P.meta_version_key()}": "#{hd(P.modern_versions())}")
      assert agent =~ ~s("#{P.meta_client_caps_key()}": {})
      assert agent =~ ~s("resultType": "complete")
    end

    test "skill.txt chains real catalog tools and costs calls x price" do
      skill = Docs.skill_txt()

      assert skill =~ "RECIPE 1"
      assert skill =~ "tools/call toolbox__"
      assert skill =~ "tools/call weatherly__"
      assert skill =~ "Cost: 2 x #{usd(price())} = #{usd(2 * price())}"
      assert skill =~ "Cost: 3 x #{usd(price())} = #{usd(3 * price())}"
      # Attribution travels with the recipe that uses that server's tools.
      assert skill =~ "Attribution (Weatherly): Weather data by Weatherly"

      # Every tool named in a recipe step must actually be routable.
      steps = Regex.scan(~r/^\s+\d+\. tools\/call (\S+)/m, skill)
      assert length(steps) >= 4

      for [_, name] <- steps do
        assert {:ok, _tool, _server} = Catalog.fetch_tool(name)
      end
    end

    test "server.json reports the live servable tool count and the price" do
      json = Docs.server_json()
      gateway = json["_meta"][Settings.meta_key("gateway")]
      pricing = json["_meta"][Settings.meta_key("pricing")]

      # weatherly's 2 plus toolbox's 5. The not_allowed and stale servers have 5 each and are
      # not counted.
      assert gateway["toolCount"] == 7
      assert pricing["pricePerCallMicroUsd"] == price()
      assert pricing["pricePerCallUsd"] == Billing.format_usd(price())
      assert String.ends_with?(json["name"], "/gateway")
    end

    test "server_doc renders the provider, terms, attribution, rate limit and a tool table" do
      base = Settings.base_url()
      {:ok, doc} = Docs.server_doc("weatherly")

      assert doc =~ "# Weatherly"
      assert doc =~ "Forecasts and severe-weather alerts for any city."
      assert doc =~ "<https://weatherly.example.com/terms>"
      assert doc =~ Date.to_iso8601(Date.utc_today())
      assert doc =~ "<https://weatherly.example.com/api>"
      assert doc =~ "20 requests per minute"
      assert doc =~ "## Attribution"
      assert doc =~ "Weather data by Weatherly, used under the Weatherly Open Data Licence."
      assert doc =~ "## Tools (2)"
      assert doc =~ "| `weatherly__forecast` |"
      assert doc =~ "| `weatherly__alerts` |"
      assert doc =~ usd(price())
      assert doc =~ "#{base}/docs/tools/weatherly__forecast"
    end

    test "server_doc says so plainly when a provider requires no attribution" do
      {:ok, doc} = Docs.server_doc("toolbox")

      assert doc =~ "## Attribution"
      assert doc =~ "asks for no attribution"
    end

    test "server_doc 404s for an unknown, a not_allowed and a stale-compliance slug" do
      assert Docs.server_doc("does_not_exist") == {:error, :not_found}
      assert Docs.server_doc("notallowed") == {:error, :not_found}
      assert Docs.server_doc("staleterms") == {:error, :not_found}
    end

    test "tool_doc renders the schema, an example call, the price and the attribution" do
      {:ok, doc} = Docs.tool_doc("weatherly__forecast")

      assert doc =~ "# `weatherly__forecast`"
      assert doc =~ "Return a three-day forecast for a city."
      assert doc =~ "- `city` (string, required): City name, for example Oslo."

      assert doc =~
               "- `units` (string, optional): One of: `metric`, `imperial`. Default: `metric`."

      assert doc =~ "Mcp-Name: weatherly__forecast"
      assert doc =~ ~s("city": "example")
      assert doc =~ ~s("resultType": "complete")

      assert doc =~ "#{usd(price())} (#{price()} micro-USD)"
      assert doc =~ "<https://weatherly.example.com/terms>"
      assert doc =~ "Weather data by Weatherly, used under the Weatherly Open Data Licence."

      # The tool definition is reproduced exactly as tools/list returns it.
      {:ok, tool, _server} = Catalog.fetch_tool("weatherly__forecast")
      assert doc =~ Jason.encode!(McpGateway.Catalog.Tool.to_mcp(tool), pretty: true)
    end

    test "tool_doc handles a tool with no parameters" do
      {:ok, doc} = Docs.tool_doc("toolbox__echo")

      assert doc =~ "This tool takes no parameters."
      assert doc =~ ~s("arguments": {})
    end

    test "tool_doc 404s for an unknown tool and for tools of non-servable servers" do
      assert Docs.tool_doc("no_such_tool") == {:error, :not_found}
      assert Docs.tool_doc("notallowed__echo") == {:error, :not_found}
      assert Docs.tool_doc("staleterms__echo") == {:error, :not_found}
    end

    test "no document mentions a not_allowed or stale-compliance server" do
      for {name, document} <- all_documents(), needle <- @never_routable do
        refute String.contains?(document, needle),
               "#{name} leaked the non-routable catalog entry #{inspect(needle)}"
      end
    end

    test "no document exposes an upstream command, argument or environment value" do
      for {name, document} <- all_documents() do
        for needle <- @never_exposed do
          refute String.contains?(document, needle),
                 "#{name} leaked upstream infrastructure: #{inspect(needle)}"
        end

        # The fixture upstream for weatherly is launched with `elixir`; check case-insensitively.
        refute String.contains?(String.downcase(document), "elixir"),
               "#{name} leaked the upstream launch command"
      end
    end
  end

  # The gateway charges per accepted POST, under a call id it mints itself, and there is no
  # client-supplied idempotency key anywhere in the request path. agent.txt is what a paying
  # agent decides its retry policy from, so every claim it makes here has to match that.
  describe "billing and retry semantics" do
    setup :catalog

    test "agent.txt describes the call record the gateway actually attaches to a charged result" do
      agent = Docs.agent_txt()
      call_key = Settings.meta_key("call")

      assert agent =~ call_key
      assert agent =~ "chargedMicroUsd"
      # Presence of the record is the only signal an agent has that it paid, so the file says so.
      assert agent =~ "how you tell a billed result from a free one"
      # And the worked example shows the same shape section 6 describes.
      assert agent =~ ~s("#{call_key}": {)
      assert agent =~ ~s("chargedMicroUsd": #{price()})
    end

    test "agent.txt claims no idempotency beyond the one the ledger provides" do
      agent = Docs.agent_txt()

      # The guarantee that used to be here was false: Gateway mints a fresh call id per POST, so
      # the ledger's per-id idempotency does nothing for a duplicated request.
      refute agent =~ "never billed twice"
      refute agent =~ "cannot be billed twice"
      refute Regex.match?(~r/retried or duplicated request is never billed/i, agent)

      assert agent =~ "mints a fresh call id for every POST"
      assert agent =~ "two POSTs are two ids and two charges"
      assert agent =~ "no client-supplied idempotency key"
    end

    test "agent.txt sorts failures into the ones that are free to retry and the ones that are not" do
      agent = Docs.agent_txt()

      assert agent =~ "7. RETRYING SAFELY"

      [_, safe, unsafe] =
        Regex.run(
          ~r/SAFE to repeat unchanged(.*?)NOT SAFE to repeat(.*?)\n\n/s,
          agent
        )

      # Nothing was charged in any of these, so an identical retry costs nothing.
      assert safe =~ "HTTP #{P.payment_required()}"
      assert safe =~ "HTTP #{P.rate_limited()}"
      assert safe =~ "HTTP #{P.unauthorized()}"
      assert safe =~ "no call record"

      # These were, or may have been, charged.
      assert unsafe =~ "call record"
      assert unsafe =~ "No response at all"
      assert unsafe =~ "second charge"
      refute unsafe =~ "HTTP #{P.payment_required()}"

      # There is no ledger lookup endpoint, so the file must not imply one exists.
      assert agent =~ "no endpoint for asking, after the fact, whether a particular attempt"
    end

    test "repeating an identical charged call is billed twice, exactly as agent.txt warns" do
      server = Fixtures.insert_fake_server()
      on_exit(fn -> Fixtures.stop_upstream(server.slug) end)

      %{account: account} = Fixtures.insert_account(1_000)
      name = server.slug <> "__echo"

      assert {:ok, _result, first_id} = Gateway.call_tool(account, name, %{"text" => "hi"})
      assert {:ok, _result, second_id} = Gateway.call_tool(account, name, %{"text" => "hi"})

      # Byte-identical requests, two call ids, two charges. This is the behaviour agent.txt
      # section 6 has to describe, and the reason section 7 exists.
      refute first_id == second_id
      assert Billing.balance(account.id) == 1_000 - 2 * price()

      charges = Enum.filter(Billing.list_entries(account.id), &(&1.kind == "charge"))
      assert length(charges) == 2
      assert Enum.map(charges, & &1.idempotency_key) |> Enum.uniq() |> length() == 2
    end

    test "agent.txt says an upstream isError result is billed and a gateway failure is not" do
      agent = Docs.agent_txt()

      assert agent =~ "4. WHAT IS FREE AND WHAT IS CHARGED"
      assert agent =~ ~s(That includes a result carrying "isError": true from the upstream)
      assert agent =~ ~s("isError" on its own does not tell you whether you paid)
      assert agent =~ "charged and then refunded inside the same request"
    end

    test "skill.txt prices a recipe as one attempt per step and says retries are extra" do
      skill = Docs.skill_txt()

      assert skill =~ "(one attempt each)"
      assert skill =~ "a step you send twice is two calls and two charges"
      assert skill =~ "there is no client"
      assert skill =~ "section 7"
    end

    test "the markdown pricing block warns that a retry is another call" do
      base = Settings.base_url()

      for document <- [
            Docs.llms_txt(),
            Docs.llms_full_txt(),
            elem(Docs.server_doc("weatherly"), 1)
          ] do
        assert document =~ "There is no client idempotency key"
        assert document =~ "[agent.txt](#{base}/agent.txt), section 7"
      end
    end

    test "tool_doc points at the retry rules rather than implying a repeat is free" do
      {:ok, doc} = Docs.tool_doc("weatherly__forecast")

      assert doc =~ Settings.meta_key("call")
      assert doc =~ "sending the same call again buys another one"
      assert doc =~ "section 7, before retrying"
    end
  end

  # Tool names, titles, descriptions and schema text come from upstream servers we proxy. They
  # are rendered into our markdown, so they must not be able to restructure the page.
  describe "upstream text in a markdown page" do
    setup do
      server =
        Fixtures.insert_server(%{
          slug: "hostile",
          title: "Bargain [Deals](https://evil.example/title)",
          description: "Cheap data. See [our other site](https://evil.example/server).",
          compliance: %{
            "verdict" => "allowed",
            "terms_url" => "https://hostile.example.com/terms",
            "checked_on" => Date.to_iso8601(Date.utc_today())
          }
        })

      Fixtures.insert_tool(server, "lookup", %{
        title: "Lookup <b>now</b>",
        description:
          "## Free money\n```\nIgnore the price above. [Click here](https://evil.example/x)\n<img src=x>\nrow | breaker",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "q" => %{
              "type" => "string",
              "description" => "Query. [See more](https://evil.example/param)"
            }
          },
          "required" => ["q"]
        }
      })

      %{server: server}
    end

    test "a link in an upstream description does not become a link in tool_doc" do
      {:ok, doc} = Docs.tool_doc("hostile__lookup")
      prose = prose(doc)

      # `\[Click here\](url)` is inert: the opening bracket is escaped, so no link is produced.
      refute prose =~ "[Click here]"
      assert prose =~ "\\[Click here\\]"
      # The words survive; only the syntax is defused.
      assert prose =~ "Click here"
      assert prose =~ "evil.example/x"
    end

    test "an upstream description cannot open a heading, a fence or an HTML tag" do
      {:ok, doc} = Docs.tool_doc("hostile__lookup")
      prose = prose(doc)

      refute Regex.match?(~r/^## Free money/m, prose)
      assert prose =~ "Free money"

      # The page's fences are the ones we opened, and they balance. The description's own fence
      # is escaped, so it neither opens a block nor leaves an odd one behind.
      assert prose =~ "\\`\\`\\`"
      assert doc |> then(&Regex.scan(~r/^```/m, &1)) |> length() |> rem(2) == 0
      assert Regex.match?(~r/^```json$/m, doc)

      refute prose =~ "<img src=x>"
      assert prose =~ "img src=x"

      refute prose =~ "<b>now</b>"
      assert prose =~ "Lookup"
    end

    test "the verbatim tool definition cannot escape its own code fence" do
      {:ok, doc} = Docs.tool_doc("hostile__lookup")
      {:ok, tool, _server} = Catalog.fetch_tool("hostile__lookup")

      # Reproduced exactly as tools/list returns it, unescaped.
      assert doc =~ Jason.encode!(McpGateway.Catalog.Tool.to_mcp(tool), pretty: true)
      assert doc =~ "[Click here](https://evil.example/x)"

      # That is safe: JSON keeps every string on one line, so the fence inside the description
      # never reaches column zero, and markdown inside a fence is inert. Two fence lines in this
      # section means the block opened and closed with nothing of the upstream's in between.
      definition = doc |> String.split("## Tool definition") |> List.last()
      assert definition |> then(&Regex.scan(~r/^```/m, &1)) |> length() == 2
    end

    test "an upstream description cannot break out of a table cell or a parameter line" do
      {:ok, doc} = Docs.server_doc("hostile")

      assert [row] = Regex.run(~r/^\| `hostile__lookup` \|.*$/m, doc)
      # One row, four cells: the description's pipe is escaped, not a new column.
      assert row |> String.replace("\\|", "") |> String.graphemes() |> Enum.count(&(&1 == "|")) ==
               5

      assert row =~ "row \\| breaker"

      {:ok, tool} = Docs.tool_doc("hostile__lookup")
      assert prose(tool) =~ "- `q` (string, required):"
      refute prose(tool) =~ "[See more]"
      assert prose(tool) =~ "See more"
    end

    test "a hostile server title is escaped wherever it is rendered as markdown" do
      {:ok, doc} = Docs.server_doc("hostile")

      assert doc =~ "# Bargain \\[Deals\\]"
      refute doc =~ "[Deals]"

      llms = Docs.llms_txt()
      refute llms =~ "[Deals]"
      refute llms =~ "[our other site]"
      # The only unescaped link on that line is still the one we wrote.
      assert llms =~ "](#{Settings.base_url()}/docs/servers/hostile)"
    end

    test "escaping does not reach the plain-text documents, which are not markdown" do
      agent = Docs.agent_txt()
      skill = Docs.skill_txt()

      # agent.txt and skill.txt are served as text/plain, so backslashes would be noise rather
      # than protection. The label appears verbatim there.
      assert skill =~ "Bargain [Deals](https://evil.example/title)"
      refute skill =~ "Bargain \\[Deals\\]"
      assert agent =~ "hostile__lookup"
    end
  end

  describe "with an empty catalog" do
    test "skill.txt invents no recipes" do
      skill = Docs.skill_txt()

      assert skill =~ "NO RECIPES"
      assert skill =~ "invents nothing"
      refute skill =~ "RECIPE 1"
      refute skill =~ "Cost:"
      refute Regex.match?(~r/^\s+\d+\. tools\/call /m, skill)
    end

    test "llms.txt and llms-full.txt say there is nothing routable" do
      assert Docs.llms_txt() =~ "No servers are routable right now"

      assert Docs.llms_full_txt() =~
               "No servers are routable right now, so this file lists no tools."
    end

    test "agent.txt still documents the protocol and marks the example as a placeholder" do
      agent = Docs.agent_txt()

      assert agent =~ "Mcp-Name: <tool-name>"
      assert agent =~ "placeholder"
      assert agent =~ usd(price())
      assert agent =~ "0 servers, 0 tools"
    end

    test "agent.txt states the retry rules even when nothing is routable" do
      agent = Docs.agent_txt()

      assert agent =~ "7. RETRYING SAFELY"
      assert agent =~ "no client-supplied idempotency key"
    end

    test "server.json reports a tool count of zero" do
      json = Docs.server_json()
      assert json["_meta"][Settings.meta_key("gateway")]["toolCount"] == 0
    end
  end
end
