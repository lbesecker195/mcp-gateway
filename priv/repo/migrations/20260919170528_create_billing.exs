defmodule McpGateway.Repo.Migrations.CreateBilling do
  use Ecto.Migration

  def up do
    create table(:accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :balance_micro_usd, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create constraint(:accounts, :balance_non_negative, check: "balance_micro_usd >= 0")

    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key_prefix, :string, null: false
      add :key_hash, :string, null: false
      add :revoked_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:account_id])

    create table(:ledger_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :restrict), null: false
      add :kind, :string, null: false
      # Signed: charges are negative, top-ups and refunds are positive.
      add :amount_micro_usd, :bigint, null: false
      add :balance_after_micro_usd, :bigint, null: false
      add :idempotency_key, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:ledger_entries, [:idempotency_key])
    create index(:ledger_entries, [:account_id, :inserted_at])

    create constraint(:ledger_entries, :kind_valid,
             check: "kind IN ('topup', 'charge', 'refund', 'adjustment')"
           )

    create constraint(:ledger_entries, :amount_sign_matches_kind,
             check:
               "(kind = 'charge' AND amount_micro_usd < 0) OR " <>
                 "(kind IN ('topup', 'refund') AND amount_micro_usd > 0) OR kind = 'adjustment'"
           )

    # The ledger is append-only: history is corrected with new entries, never edited.
    execute """
    CREATE FUNCTION ledger_entries_append_only() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'ledger_entries is append-only';
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER ledger_entries_no_update_delete
    BEFORE UPDATE OR DELETE ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION ledger_entries_append_only()
    """
  end

  def down do
    execute "DROP TRIGGER ledger_entries_no_update_delete ON ledger_entries"
    execute "DROP FUNCTION ledger_entries_append_only()"
    drop table(:ledger_entries)
    drop table(:api_keys)
    drop table(:accounts)
  end
end
