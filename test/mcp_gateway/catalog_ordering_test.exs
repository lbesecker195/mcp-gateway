defmodule McpGateway.CatalogOrderingTest do
  @moduledoc """
  What we put in front of people is ordered by how much upstream headroom a provider has.

  This is not cosmetic. A provider's rate limit is a condition of the terms that let us proxy
  it at all, so the tightest providers — arXiv at 20 requests a minute, BLS at 450 a day —
  must not be the first thing a visitor clicks.
  """
  use McpGateway.DataCase, async: true

  alias McpGateway.{Catalog, Fixtures}

  test "computes requests per minute from the published window" do
    minute = Fixtures.insert_server(%{rate_limit: %{"requests" => 600, "window_ms" => 60_000}})
    daily = Fixtures.insert_server(%{rate_limit: %{"requests" => 450, "window_ms" => 86_400_000}})
    none = Fixtures.insert_server(%{rate_limit: nil})

    assert Catalog.requests_per_minute(minute) == 600.0
    assert_in_delta Catalog.requests_per_minute(daily), 0.3125, 0.01
    assert Catalog.requests_per_minute(none) == nil
  end

  test "orders the roomiest provider first and the tightest last" do
    roomy =
      Fixtures.insert_fake_server(%{rate_limit: %{"requests" => 1000, "window_ms" => 60_000}})

    tight = Fixtures.insert_fake_server(%{rate_limit: %{"requests" => 20, "window_ms" => 60_000}})

    slugs = Catalog.list_servers_by_capacity() |> Enum.map(& &1.slug)

    assert Enum.find_index(slugs, &(&1 == roomy.slug)) <
             Enum.find_index(slugs, &(&1 == tight.slug))
  end

  test "a daily quota sorts below a per-minute one, not above it" do
    per_minute =
      Fixtures.insert_fake_server(%{rate_limit: %{"requests" => 50, "window_ms" => 60_000}})

    per_day =
      Fixtures.insert_fake_server(%{rate_limit: %{"requests" => 450, "window_ms" => 86_400_000}})

    slugs = Catalog.list_servers_by_capacity() |> Enum.map(& &1.slug)

    assert Enum.find_index(slugs, &(&1 == per_minute.slug)) <
             Enum.find_index(slugs, &(&1 == per_day.slug)),
           "450/day is a far tighter budget than 50/minute; the raw number must not decide"
  end

  test "a provider with no published limit sorts last rather than first" do
    unknown = Fixtures.insert_fake_server(%{rate_limit: nil})
    known = Fixtures.insert_fake_server(%{rate_limit: %{"requests" => 10, "window_ms" => 60_000}})

    slugs = Catalog.list_servers_by_capacity() |> Enum.map(& &1.slug)

    assert Enum.find_index(slugs, &(&1 == known.slug)) <
             Enum.find_index(slugs, &(&1 == unknown.slug))
  end

  test "excludes anything the compliance gate would not serve" do
    blocked = Fixtures.insert_fake_server(%{compliance_verdict: "not_allowed"})
    stale = Fixtures.insert_fake_server(%{compliance_checked_on: ~D[2000-01-01]})

    slugs = Catalog.list_servers_by_capacity() |> Enum.map(& &1.slug)

    refute blocked.slug in slugs
    refute stale.slug in slugs
  end
end
