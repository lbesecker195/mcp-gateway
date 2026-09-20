defmodule McpGatewayWeb.TrialController do
  @moduledoc """
  The free trial and the public `/try` demo.

  Both spend real money, so both are rate limited per client address. Neither is a substitute
  for verification: see the note on `signup/2`.
  """

  use McpGatewayWeb, :controller

  alias McpGateway.{Billing, Demo, RateLimiter, Settings}

  @doc """
  Creates an account, grants the one-off trial credit and returns the API key once.

  The key is shown exactly here and never again: only its hash is stored, so a lost key is
  replaced rather than recovered.

  This endpoint is off unless `:signup_enabled` is set. An open endpoint that mints real credit
  with no email, payment method or challenge can be farmed in a loop; the per-address limit
  below raises the cost of doing so but does not prevent it. Turn this on only alongside
  verification, or with a trial small enough that farming it is not worth the effort.
  """
  def signup(conn, params) do
    cond do
      not Settings.get(:signup_enabled) ->
        error(conn, 404, "signup_disabled", "Self-serve signup is not enabled on this gateway.")

      rate_limited?(conn, :signup) ->
        error(conn, 429, "rate_limited", "Too many signups from this address. Try again later.")

      true ->
        create_trial_account(conn, params["name"])
    end
  end

  defp create_trial_account(conn, name) do
    label = name |> to_string() |> String.slice(0, 60) |> String.trim()
    label = if label == "", do: "trial account", else: label

    with {:ok, account} <- Billing.create_account(label),
         {:ok, _entry} <- Billing.grant_trial(account.id),
         {:ok, key, _} <- Billing.create_api_key(account) do
      credit = Settings.trial_credit_micro_usd()

      json(conn, %{
        "apiKey" => key,
        "accountId" => account.id,
        "creditMicroUsd" => credit,
        "creditUsd" => Billing.format_usd(credit),
        "pricePerCallMicroUsd" => Settings.price_micro_usd(),
        "callsIncluded" => div(credit, Settings.price_micro_usd()),
        "endpoint" => "#{Settings.base_url()}/mcp",
        "docs" => "#{Settings.base_url()}/agent.txt",
        "note" => "Store this key now. Only its hash is kept, so it cannot be shown again."
      })
    else
      {:error, reason} ->
        error(conn, 500, "signup_failed", "Could not create the account: #{inspect(reason)}")
    end
  end

  @doc """
  Runs one whitelisted demo example through the real gateway, billed to the gateway's own
  demo account. See `McpGateway.Demo` for why only fixed examples can be run.
  """
  def try_call(conn, params) do
    if rate_limited?(conn, :demo) do
      error(
        conn,
        429,
        "rate_limited",
        "The demo allows a few calls per address per hour. Get your own free credit to keep going."
      )
    else
      run_demo(conn, params["example"], params["query"])
    end
  end

  defp run_demo(conn, id, query) when is_binary(id) do
    case Demo.run(id, query) do
      {:ok, outcome} ->
        json(conn, %{
          "ok" => true,
          "tool" => outcome.tool,
          "arguments" => outcome.arguments,
          "chargedMicroUsd" => outcome.charged_micro_usd,
          "chargedUsd" => Billing.format_usd(outcome.charged_micro_usd),
          "callId" => outcome.call_id,
          "text" => extract_text(outcome.result),
          "isError" => outcome.result["isError"] == true
        })

      {:error, reason} ->
        json(conn, %{"ok" => false, "message" => Demo.explain(reason)})
    end
  end

  defp run_demo(conn, _id, _query),
    do: error(conn, 400, "bad_request", "Name one of the demo examples.")

  # The demo shows the text an agent would see. Non-text content blocks are summarised rather
  # than dumped, so a base64 image never lands in the page.
  defp extract_text(result) do
    (result["content"] || [])
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => type} -> "[#{type} content]"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> String.slice(0, 4000)
  end

  defp rate_limited?(conn, kind) do
    {limit, window} =
      case kind do
        :signup -> Settings.get(:signup_rate_limit)
        :demo -> {12, 3_600_000}
      end

    match?({:error, :rate_limited, _}, RateLimiter.check({kind, client_ip(conn)}, limit, window))
  end

  # Behind nginx the peer is the proxy, so prefer the forwarded address. It is client-supplied
  # and therefore spoofable: this bounds casual abuse, it is not an identity.
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> hd() |> String.trim() |> String.slice(0, 45)
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp error(conn, status, code, message) do
    conn |> put_status(status) |> json(%{"ok" => false, "error" => code, "message" => message})
  end
end
