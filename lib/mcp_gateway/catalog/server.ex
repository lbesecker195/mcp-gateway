defmodule McpGateway.Catalog.Server do
  @moduledoc """
  One upstream MCP server we route to, with its compliance record. Rows are written only by
  `McpGateway.Catalog.Sync` from reviewed catalog files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]

  @fields ~w(name slug version title description website_url repository upstream rate_limit
             compliance compliance_verdict compliance_checked_on docs status published_at)a
  @required ~w(name slug version description upstream compliance compliance_verdict
               compliance_checked_on published_at)a

  schema "servers" do
    field :name, :string
    field :slug, :string
    field :version, :string
    field :title, :string
    field :description, :string
    field :website_url, :string
    field :repository, :map
    field :upstream, :map
    field :rate_limit, :map
    field :compliance, :map
    field :compliance_verdict, :string
    field :compliance_checked_on, :date
    field :docs, :map, default: %{}
    field :status, :string, default: "active"
    field :published_at, :utc_datetime

    has_many :tools, McpGateway.Catalog.Tool

    timestamps()
  end

  def changeset(server, attrs) do
    server
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_]{1,30}$/)
    |> validate_format(:name, ~r/^[a-zA-Z0-9.-]+\/[a-zA-Z0-9._-]+$/)
    |> validate_length(:description, max: 100)
    |> validate_inclusion(:compliance_verdict, McpGateway.Catalog.Compliance.verdicts())
    |> validate_inclusion(:status, ~w(active deprecated))
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
