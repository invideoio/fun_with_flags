defmodule FunWithFlags.Dev.EctoRepo.Migrations.AddCreatedAtToFeatureFlagsTable do
  use Ecto.Migration

  def up do
    alter table(:fun_with_flags_toggles) do
      add :created_at, :utc_datetime, null: true
    end

    flush()

    # Back-propagate created_at from the audit log table if it exists.
    # For each flag, use the earliest audit log entry as the creation time.
    backfill_created_at_from_audit_logs()
  end

  def down do
    alter table(:fun_with_flags_toggles) do
      remove :created_at
    end
  end

  defp backfill_created_at_from_audit_logs do
    audit_table = "fun_with_flags_audit_logs"

    if audit_table_exists?(audit_table) do
      case repo().__adapter__() do
        Ecto.Adapters.Postgres ->
          execute """
          UPDATE fun_with_flags_toggles
          SET created_at = audit_earliest.earliest
          FROM (
            SELECT flag_name, MIN(inserted_at) AS earliest
            FROM #{audit_table}
            GROUP BY flag_name
          ) AS audit_earliest
          WHERE fun_with_flags_toggles.flag_name = audit_earliest.flag_name
            AND fun_with_flags_toggles.created_at IS NULL
          """

        Ecto.Adapters.MyXQL ->
          execute """
          UPDATE fun_with_flags_toggles t
          INNER JOIN (
            SELECT flag_name, MIN(inserted_at) AS earliest
            FROM #{audit_table}
            GROUP BY flag_name
          ) audit_earliest ON t.flag_name = audit_earliest.flag_name
          SET t.created_at = audit_earliest.earliest
          WHERE t.created_at IS NULL
          """

        Ecto.Adapters.SQLite3 ->
          execute """
          UPDATE fun_with_flags_toggles
          SET created_at = (
            SELECT MIN(inserted_at)
            FROM #{audit_table}
            WHERE #{audit_table}.flag_name = fun_with_flags_toggles.flag_name
          )
          WHERE created_at IS NULL
            AND flag_name IN (SELECT DISTINCT flag_name FROM #{audit_table})
          """

        _ ->
          :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp audit_table_exists?(table_name) do
    case repo().__adapter__() do
      Ecto.Adapters.Postgres ->
        %{num_rows: n} = repo().query!(
          "SELECT 1 FROM information_schema.tables WHERE table_name = $1",
          [table_name]
        )
        n > 0

      Ecto.Adapters.MyXQL ->
        %{num_rows: n} = repo().query!(
          "SELECT 1 FROM information_schema.tables WHERE table_name = ?",
          [table_name]
        )
        n > 0

      Ecto.Adapters.SQLite3 ->
        %{rows: rows} = repo().query!(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?1",
          [table_name]
        )
        length(rows) > 0

      _ ->
        false
    end
  rescue
    _ -> false
  end
end
