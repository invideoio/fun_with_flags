if Code.ensure_loaded?(Ecto.Adapters.SQL) do

defmodule FunWithFlags.AuditLog do
  @moduledoc false

  require Logger
  import Ecto.Query
  alias FunWithFlags.AuditLog.Record
  alias FunWithFlags.{Config, Flag, Gate}

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

  @doc """
  Lists audit log entries with optional filtering and pagination.

  ## Options

    * `:flag_name` - partial match on flag name (case-insensitive)
    * `:page` - page number (1-based, default 1)
    * `:per_page` - results per page (default 25, max 100)

  Returns `{:ok, %{records: [...], total: int, page: int, per_page: int, total_pages: int}}`
  """
  @spec list(keyword()) :: {:ok, map()} | {:error, any()}
  def list(opts \\ []) do
    if Config.audit_log_enabled?() do
      do_list(opts)
    else
      {:error, :audit_log_not_configured}
    end
  end

  @doc """
  Lists audit log entries for a specific flag with pagination.

  ## Options

    * `:page` - page number (1-based, default 1)
    * `:per_page` - results per page (default 25, max 100)

  Returns `{:ok, %{records: [...], total: int, page: int, per_page: int, total_pages: int}}`
  """
  @spec list_for_flag(String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def list_for_flag(flag_name, opts \\ []) do
    if Config.audit_log_enabled?() do
      do_list_for_flag(flag_name, opts)
    else
      {:error, :audit_log_not_configured}
    end
  end

  defp do_list(opts) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = opts |> Keyword.get(:per_page, 25) |> max(1) |> min(100)
    flag_name = Keyword.get(opts, :flag_name)
    repo = Config.audit_log_repo()

    base_query = from(r in Record, order_by: [desc: r.inserted_at, desc: r.id])

    base_query =
      if flag_name && flag_name != "" do
        search = "%" <> String.downcase(flag_name) <> "%"
        from(r in base_query, where: like(fragment("LOWER(?)", r.flag_name), ^search))
      else
        base_query
      end

    total = repo.aggregate(base_query, :count)
    total_pages = max(ceil(total / per_page), 1)
    offset = (page - 1) * per_page

    records =
      base_query
      |> limit(^per_page)
      |> offset(^offset)
      |> repo.all()

    {:ok, %{records: records, total: total, page: page, per_page: per_page, total_pages: total_pages}}
  rescue
    e ->
      Logger.warning("FunWithFlags.AuditLog: exception during list: #{Exception.message(e)}")
      {:error, e}
  end

  defp do_list_for_flag(flag_name, opts) do
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = opts |> Keyword.get(:per_page, 25) |> max(1) |> min(100)
    repo = Config.audit_log_repo()

    base_query =
      from(r in Record,
        where: r.flag_name == ^flag_name,
        order_by: [desc: r.inserted_at, desc: r.id]
      )

    total = repo.aggregate(base_query, :count)
    total_pages = max(ceil(total / per_page), 1)
    offset = (page - 1) * per_page

    records =
      base_query
      |> limit(^per_page)
      |> offset(^offset)
      |> repo.all()

    {:ok, %{records: records, total: total, page: page, per_page: per_page, total_pages: total_pages}}
  rescue
    e ->
      Logger.warning("FunWithFlags.AuditLog: exception during list_for_flag: #{Exception.message(e)}")
      {:error, e}
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

    flag_name_str = to_string(flag_name)

    params = %{
      flag_name: if(flag_name_str == "_bulk_operation", do: nil, else: flag_name_str),
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
