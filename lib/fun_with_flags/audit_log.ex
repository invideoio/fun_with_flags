if Code.ensure_loaded?(Ecto.Adapters.SQL) do

defmodule FunWithFlags.AuditLog do
  @moduledoc false

  require Logger
  alias FunWithFlags.{Config, Flag, Gate}
  alias FunWithFlags.AuditLog.Record

  @doc """
  Logs an audit event for a flag mutation.

  Returns `:ok` always — audit logging is best-effort and never
  fails the original operation.

  ## Options

    * `:gate` - the `%Gate{}` involved in the operation
    * `:user_id` - the user who performed the action
    * `:flag_state_before` - a `%Flag{}` snapshot before mutation (for deletes)
    * `:operation_metadata` - a map of extra metadata (for bulk ops)
  """
  @spec log(atom | String.t(), atom, keyword()) :: :ok
  def log(action, flag_name, opts \\ []) do
    if Config.audit_log_enabled?() do
      do_log(action, flag_name, opts)
    else
      :ok
    end
  end

  defp do_log(action, flag_name, opts) do
    gate = Keyword.get(opts, :gate)
    user_id = Keyword.get(opts, :user_id)
    flag_state_before = Keyword.get(opts, :flag_state_before)
    operation_metadata = Keyword.get(opts, :operation_metadata)

    data = %{
      action: to_string(action),
      flag_name: to_string(flag_name)
    }

    data = if gate, do: Map.put(data, :gate, serialize_gate(gate)), else: data
    data = if flag_state_before, do: Map.put(data, :flag_state_before, serialize_flag(flag_state_before)), else: data
    data = if operation_metadata, do: Map.put(data, :operation_metadata, operation_metadata), else: data

    params = %{
      user_id: user_id,
      data: data,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    changeset = Record.changeset(%Record{}, params)

    case Config.audit_log_repo().insert(changeset) do
      {:ok, _record} ->
        :ok
      {:error, changeset} ->
        Logger.warning("FunWithFlags.AuditLog: failed to insert audit log: #{inspect(changeset.errors)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("FunWithFlags.AuditLog: exception during audit logging: #{Exception.message(e)}")
      :ok
  end

  defp serialize_flag(%Flag{name: name, gates: gates}) do
    %{
      name: to_string(name),
      gates: Enum.map(gates, &serialize_gate/1)
    }
  end

  defp serialize_gate(%Gate{type: type, for: target, enabled: enabled}) do
    gate = %{type: to_string(type), enabled: enabled}
    if target, do: Map.put(gate, :target, to_string(target)), else: gate
  end

end

end # Code.ensure_loaded?
