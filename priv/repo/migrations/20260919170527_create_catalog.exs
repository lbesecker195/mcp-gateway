defmodule McpGateway.Repo.Migrations.CreateCatalog do
  use Ecto.Migration

  def change do
    create table(:servers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :version, :string, null: false
      add :title, :string
      add :description, :text, null: false
      add :website_url, :string
      add :repository, :map
      add :upstream, :map, null: false
      add :rate_limit, :map
      add :compliance, :map, null: false
      add :compliance_verdict, :string, null: false
      add :compliance_checked_on, :date, null: false
      add :docs, :map, null: false, default: %{}
      add :status, :string, null: false, default: "active"
      add :published_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:servers, [:name])
    create unique_index(:servers, [:slug])

    create constraint(:servers, :compliance_verdict_valid,
             check: "compliance_verdict IN ('allowed', 'not_allowed', 'unknown')"
           )

    create constraint(:servers, :status_valid, check: "status IN ('active', 'deprecated')")

    create table(:tools, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :server_id, references(:servers, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :upstream_name, :string, null: false
      add :title, :string
      add :description, :text
      add :input_schema, :map, null: false
      add :output_schema, :map
      add :annotations, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tools, [:name])
    create unique_index(:tools, [:server_id, :upstream_name])
  end
end
