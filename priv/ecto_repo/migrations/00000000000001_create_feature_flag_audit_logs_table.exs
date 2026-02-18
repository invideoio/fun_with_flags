defmodule FunWithFlags.Dev.EctoRepo.Migrations.CreateFeatureFlagAuditLogsTable do
  use Ecto.Migration

  # This migration assumes the default table name of "fun_with_flags_audit_logs"
  # is being used. If you have overridden that via configuration, you should
  # change this migration accordingly.

  def up do
    create table(:fun_with_flags_audit_logs, primary_key: false) do
      add :id, :bigserial, primary_key: true
      # If you configure :ecto_primary_key_type to be :binary_id, you should replace
      # the line above with:
      # add :id, :binary_id, primary_key: true
      add :flag_name, :string
      add :user_id, :string
      add :data, :map, null: false        # jsonb on Postgres; use :text on MySQL/SQLite
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:fun_with_flags_audit_logs, [:flag_name])
    create index(:fun_with_flags_audit_logs, [:user_id])
    create index(:fun_with_flags_audit_logs, [:inserted_at])
  end

  def down do
    drop table(:fun_with_flags_audit_logs)
  end
end
