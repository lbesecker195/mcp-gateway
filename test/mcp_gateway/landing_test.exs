defmodule McpGateway.LandingTest do
  @moduledoc """
  The landing page is the gateway's front door: it is what the registry entry's `websiteUrl`
  points at, what a 402 tells people to visit, and what a search engine indexes. These tests
  guard the things that would silently break it — a missing title, a stale price, a delisted
  provider still advertised, or an upstream launch command leaking into public HTML.
  """
  use McpGateway.DataCase, async: true

  alias McpGateway.{Billing, Fixtures, Landing, Settings}

  defp meta(html, name) do
    case Regex.run(~r/name="#{name}" content="(.*?)"/s, html) do
      [_, value] -> value
      _ -> nil
    end
  end

  describe "html/0" do
    test "carries the head tags a search engine needs" do
      Fixtures.insert_fake_server()
      html = Landing.html()

      assert [_, title] = Regex.run(~r/<title>(.*?)<\/title>/s, html)
      assert title =~ "MCP Gateway"

      assert String.length(title) <= 120,
             "title is #{String.length(title)} chars; keep it indexable"

      description = meta(html, "description")
      assert description =~ "Model Context Protocol"
      # Search engines truncate around 160 characters.
      assert String.length(description) in 50..160

      assert html =~ ~s(rel="canonical" href="#{Settings.canonical_base_url()}/")
      assert html =~ ~s(<meta name="viewport")
      assert html =~ ~s(property="og:title")
      assert [_, h1] = Regex.run(~r/<h1>(.*?)<\/h1>/s, html)
      assert h1 =~ "MCP Gateway"
    end

    test "answers the definitional query people actually search" do
      Fixtures.insert_fake_server()
      headings = Regex.scan(~r/<h2>(.*?)<\/h2>/s, Landing.html()) |> Enum.map(&List.last/1)

      assert Enum.any?(headings, &(&1 =~ ~r/what is an mcp gateway/i)),
             "the page must answer the definitional query; headings were #{inspect(headings)}"

      assert Enum.any?(headings, &(&1 =~ ~r/pricing/i))
    end

    test "embeds structured data that parses and states the real price" do
      Fixtures.insert_fake_server()
      [_, json] = Regex.run(~r/application\/ld\+json">(.*?)<\/script>/s, Landing.html())

      assert {:ok, data} = Jason.decode(json)
      assert data["@type"] == "WebAPI"
      assert data["offers"]["price"] == Billing.format_usd(Settings.price_micro_usd())
      assert data["offers"]["priceCurrency"] == "USD"
    end

    test "the price shown is derived from config, never hardcoded" do
      Fixtures.insert_fake_server()
      assert Landing.html() =~ "$#{Billing.format_usd(Settings.price_micro_usd())}"
    end

    test "lists servable servers and their live tool counts" do
      server = Fixtures.insert_fake_server()
      html = Landing.html()

      assert html =~ server.title
      assert html =~ "/docs/servers/#{server.slug}"
      assert html =~ "5 tools"
    end

    test "never advertises a server whose compliance verdict is not allowed" do
      blocked =
        Fixtures.insert_server(%{compliance_verdict: "not_allowed", title: "Blocked Provider"})

      Fixtures.insert_tool(blocked, "should_not_appear")

      html = Landing.html()
      refute html =~ "Blocked Provider"
      refute html =~ blocked.slug
    end

    test "never advertises a server whose compliance check has gone stale" do
      stale =
        Fixtures.insert_server(%{compliance_checked_on: ~D[2000-01-01], title: "Stale Provider"})

      html = Landing.html()
      refute html =~ "Stale Provider"
      refute html =~ stale.slug
    end

    test "never leaks an upstream launch command, argument or env var into public HTML" do
      Fixtures.insert_fake_server(%{
        upstream: %{
          "type" => "stdio",
          "command" => "npx",
          "args" => ["-y", "@someone/secret-package@1.0.0"],
          "env" => %{"UPSTREAM_TOKEN" => "s3cret"}
        }
      })

      html = Landing.html()
      refute html =~ "secret-package"
      refute html =~ "UPSTREAM_TOKEN"
      refute html =~ "s3cret"
      refute html =~ "\"command\""
    end

    test "escapes catalog text rather than interpolating it raw" do
      Fixtures.insert_server(%{title: "Ampersand & <script>bad</script>"})

      html = Landing.html()
      refute html =~ "<script>bad</script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "Ampersand &amp;"
    end

    test "renders with an empty catalog instead of crashing" do
      html = Landing.html()
      assert html =~ "<h1>MCP Gateway</h1>"
      assert html =~ "0"
    end
  end

  describe "sitemap_xml/0" do
    test "covers the landing page, the agent documents and every servable entry" do
      server = Fixtures.insert_fake_server()
      xml = Landing.sitemap_xml()

      assert xml =~ ~s(<?xml version="1.0")
      assert xml =~ "<urlset"
      assert xml =~ "<loc>#{Settings.canonical_base_url()}/</loc>"
      assert xml =~ "/llms.txt</loc>"
      assert xml =~ "/agent.txt</loc>"
      assert xml =~ "/docs/servers/#{server.slug}</loc>"
      assert xml =~ "/docs/tools/#{server.slug}__echo</loc>"
    end

    test "omits a non-compliant server" do
      blocked = Fixtures.insert_server(%{compliance_verdict: "not_allowed"})
      refute Landing.sitemap_xml() =~ blocked.slug
    end
  end

  describe "robots_txt/0" do
    test "points crawlers at the sitemap and keeps them out of the paid endpoint" do
      robots = Landing.robots_txt()

      assert robots =~ "Sitemap: #{Settings.canonical_base_url()}/sitemap.xml"
      assert robots =~ "Disallow: /mcp"
      assert robots =~ "Allow: /"
    end
  end
end
