defmodule McpGateway.TryPageTest do
  @moduledoc """
  The setup snippets are the whole value of this page. Each client uses different field names,
  and a plausible-looking snippet with the wrong one fails in a way that looks like the gateway
  is down — so the shapes are asserted here rather than trusted.
  """
  use McpGateway.DataCase, async: true

  alias McpGateway.{Settings, TryPage}

  setup do
    %{html: TryPage.html()}
  end

  test "renders and names the clients it claims to support", %{html: html} do
    for client <- ["Claude Code", "Claude Desktop", "Cursor", "VS Code", "Windsurf", "OpenAI"] do
      assert html =~ client
    end
  end

  test "VS Code uses `servers`, which is the one client that does not use `mcpServers`", %{
    html: html
  } do
    [_, vscode] = Regex.run(~r/id="panel-vscode">(.*?)<\/div>\s*<div class="panel/s, html)

    assert vscode =~ "&quot;servers&quot;"
    refute vscode =~ "&quot;mcpServers&quot;"
    assert vscode =~ "&quot;type&quot;: &quot;http&quot;"
  end

  test "Windsurf uses `serverUrl`, not `url`", %{html: html} do
    [_, windsurf] = Regex.run(~r/id="panel-windsurf">(.*?)<\/div>\s*<div class="panel/s, html)

    assert windsurf =~ "serverUrl"
    assert windsurf =~ "mcpServers"
  end

  test "Cursor uses `mcpServers` with a plain `url`", %{html: html} do
    [_, cursor] = Regex.run(~r/id="panel-cursor">(.*?)<\/div>\s*<div class="panel/s, html)

    assert cursor =~ "&quot;mcpServers&quot;"
    assert cursor =~ "&quot;url&quot;"
    refute cursor =~ "serverUrl"
  end

  test "Claude Code uses the CLI flag form, with a colon in the header", %{html: html} do
    assert html =~ "claude mcp add --transport http"
    assert html =~ ~s(--header &quot;Authorization: Bearer YOUR_KEY&quot;)
  end

  test "every snippet points at this gateway's real MCP endpoint" do
    html = TryPage.html()
    endpoint = "#{Settings.canonical_base_url()}/mcp"

    # One per client panel, plus the signup line in the transcript.
    assert length(Regex.scan(~r/#{Regex.escape(endpoint)}/, html)) >= 6
  end

  test "uses a placeholder, never a real-looking key", %{html: html} do
    assert html =~ "YOUR_KEY"
    refute html =~ ~r/mcpg_[A-Za-z0-9_-]{20,}/
  end

  test "states the price and trial from config rather than hardcoding them", %{html: html} do
    assert html =~ "$" <> McpGateway.Billing.format_usd(Settings.price_micro_usd())
    assert html =~ "$" <> McpGateway.Billing.format_usd(Settings.trial_credit_micro_usd())
  end

  test "labels the transcript as illustrative rather than implying a recording", %{html: html} do
    assert html =~ ~r/illustrative/i
  end

  test "makes no live call: no fetch, no demo endpoint", %{html: html} do
    refute html =~ "/try/call"
    refute html =~ "fetch("
  end

  test "cites a source for every client panel", %{html: html} do
    panels = Regex.scan(~r/class="panel[^"]*" id="panel-/, html) |> length()
    sources = Regex.scan(~r/class="src"/, html) |> length()

    assert panels == sources, "every client panel must cite the docs it was verified against"
    assert panels >= 6
  end

  test "leads with the conversation, not the configuration", %{html: html} do
    assert :binary.match(html, "What it looks like") < :binary.match(html, "Setup, once")
  end
end
