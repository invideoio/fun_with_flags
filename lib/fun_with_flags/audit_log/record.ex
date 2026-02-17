if Code.ensure_loaded?(Ecto.Adapters.SQL) do

defmodule FunWithFlags.AuditLog.Record do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  alias FunWithFlags.Config

  @primary_key {:id, Config.audit_log_primary_key_type_determined_at_compile_time(), autogenerate: true}

  schema Config.audit_log_table_name_determined_at_compile_time() do
    field :flag_name, :string
    field :user_id, :string
    field :data, :map
    field :inserted_at, :utc_datetime
  end

  @required_fields [:data, :inserted_at]
  @optional_fields [:flag_name, :user_id]

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end

end # Code.ensure_loaded?
