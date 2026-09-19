defmodule McpGateway.Catalog.Compliance do
  @moduledoc """
  The catalog's default-deny gate.

  A server is listed and routable only if its compliance record says `allowed` **and** that
  verdict was checked recently. An old verdict is treated as unverified: terms change, and
  we'd rather delist than serve on stale legal reading.
  """

  @verdicts ~w(allowed not_allowed unknown)

  def verdicts, do: @verdicts

  @doc "Oldest `checked_on` date that still counts as verified."
  def cutoff(today \\ Date.utc_today()) do
    Date.add(today, -McpGateway.Settings.get(:compliance_max_age_days))
  end

  def servable?(verdict, %Date{} = checked_on, today \\ Date.utc_today()) do
    verdict == "allowed" and Date.compare(checked_on, cutoff(today)) != :lt
  end

  def stale?(%Date{} = checked_on, today \\ Date.utc_today()) do
    Date.compare(checked_on, cutoff(today)) == :lt
  end
end
