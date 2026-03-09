if Code.ensure_loaded?(Ecto.Adapters.SQL) do

defmodule FunWithFlags.Store.Persistent.Ecto do
  @moduledoc false

  @behaviour FunWithFlags.Store.Persistent

  alias FunWithFlags.Gate
  alias FunWithFlags.Store.Persistent.Ecto.Record
  alias FunWithFlags.Store.Serializer.Ecto, as: Serializer

  import FunWithFlags.Config, only: [ecto_repo: 0]
  import Ecto.Query

  require Logger

  @mysql_lock_timeout_s 3
  @query_opts [fun_with_flags: true]
  @created_at_key {__MODULE__, :has_created_at_column}


  @impl true
  def worker_spec do
    nil
  end


  @impl true
  def get(flag_name) do
    name_string = to_string(flag_name)
    query = from(r in Record, where: r.flag_name == ^name_string)
    try do
      results = ecto_repo().all(query, @query_opts)
      flag = deserialize(flag_name, results)
      {:ok, flag}
    rescue
      e in [Ecto.QueryError] -> {:error, e}
    end
  end


  @impl true
  def put(flag_name, gate = %Gate{type: type})
  when type in [:percentage_of_time, :percentage_of_actors] do
    name_string = to_string(flag_name)

    find_one_q = from(
      r in Record,
      where: r.flag_name == ^name_string,
      where: r.gate_type == "percentage"
    )

    repo = ecto_repo()

    transaction_fn = case db_type(repo) do
      :postgres -> build_transaction_with_lock_postgres_fn(flag_name)
      :mysql -> &transaction_with_lock_mysql/2
      :sqlite -> &transaction_with_sqlite/2
    end

    out = transaction_fn.(repo, fn() ->
      case repo.one(find_one_q, @query_opts) do
        record = %Record{} ->
          changeset = Record.update_target(record, gate)
          do_update(repo, flag_name, changeset)
        nil ->
          changeset = Record.build(flag_name, gate)
          do_insert(repo, flag_name, changeset)
      end
    end)


    case out do
      {:ok, {:ok, result}} ->
        {:ok, result}
      {:error, _} = error ->
        error
    end
  end


  @impl true
  def put(flag_name, gate = %Gate{}) do
    changeset = Record.build(flag_name, gate)
    repo = ecto_repo()
    options = upsert_options(repo, gate)

    case do_insert(repo, flag_name, changeset, options) do
      {:ok, flag} ->
        {:ok, flag}
      other ->
        other
    end
  end


  # Returns a transaction-wrapper function for Postgres.
  #
  defp build_transaction_with_lock_postgres_fn(flag_name) do
    fn(repo, upsert_fn) ->
      repo.transaction fn() ->
        Ecto.Adapters.SQL.query!(repo,
          "SELECT pg_advisory_xact_lock(hashtext('fun_with_flags_percentage_gate_upsert'), hashtext($1))",
          [to_string(flag_name)]
        )
        upsert_fn.()
      end
    end
  end


  # Is itself a transaction-wrapper function for MySQL.
  #
  defp transaction_with_lock_mysql(repo, upsert_fn) do
    repo.transaction fn() ->
      if mysql_lock!(repo) do
        try do
          upsert_fn.()
        rescue
          e ->
            repo.rollback("Exception: #{inspect(e)}")
        else
          {:error, reason} ->
            repo.rollback("Error while upserting the gate: #{inspect(reason)}")
          {:ok, value} ->
            {:ok, value}
        after
          # This is not guaranteed to run if the VM crashes, but at least the
          # lock gets released when the MySQL client session is terminated.
          mysql_unlock!(repo)
        end
      else
        Logger.error("Couldn't acquire lock with 'SELECT GET_LOCK()' after #{@mysql_lock_timeout_s} seconds")
        repo.rollback("couldn't acquire lock")
      end
    end
  end

  # Is itself a transaction-wrapper function for SQLite.
  #
  defp transaction_with_sqlite(repo, upsert_fn) do
    repo.transaction(fn ->
      try do
        upsert_fn.()
      rescue
        e ->
          repo.rollback("Exception: #{inspect(e)}")
      else
        {:error, reason} ->
          repo.rollback("Error while upserting the gate: #{inspect(reason)}")
        {:ok, value} ->
          {:ok, value}
      end
    end)
  end


  @impl true
  def delete(flag_name, %Gate{type: type})
  when type in [:percentage_of_time, :percentage_of_actors] do
    name_string = to_string(flag_name)

    query = from(
      r in Record,
      where: r.flag_name == ^name_string
      and r.gate_type == "percentage"
    )

    try do
      {_count, _} = ecto_repo().delete_all(query, @query_opts)
      {:ok, flag} = get(flag_name)
      {:ok, flag}
    rescue
      e in [Ecto.QueryError] -> {:error, e}
    end
  end


  # Deletes one gate from the toggles table in the DB.
  # Deleting gates is idempotent and deleting unknown gates is safe.
  # A flag will continue to exist even though it has no gates.
  #
  @impl true
  def delete(flag_name, gate = %Gate{}) do
    name_string = to_string(flag_name)
    gate_type = to_string(gate.type)
    target    = Record.serialize_target(gate.for)

    query = from(
      r in Record,
      where: r.flag_name == ^name_string
      and r.gate_type == ^gate_type
      and r.target == ^target
    )

    try do
      {_count, _} = ecto_repo().delete_all(query, @query_opts)
      {:ok, flag} = get(flag_name)
      {:ok, flag}
    rescue
      e in [Ecto.QueryError] -> {:error, e}
    end
  end


  # Deletes all of of this flags' gates from the toggles table, thus deleting
  # the entire flag.
  # Deleting flags is idempotent and deleting unknown flags is safe.
  # After the operation fetching the now-deleted flag will return the default
  # empty flag structure.
  #
  @impl true
  def delete(flag_name) do
    name_string = to_string(flag_name)

    query = from(
      r in Record,
      where: r.flag_name == ^name_string
    )

    try do
      {_count, _} = ecto_repo().delete_all(query, @query_opts)
      {:ok, flag} = get(flag_name)
      {:ok, flag}
    rescue
      e in [Ecto.QueryError] -> {:error, e}
    end
  end


  @impl true
  def all_flags do
    repo = ecto_repo()

    flags =
      Record
      |> repo.all(@query_opts)
      |> Enum.group_by(&(&1.flag_name))
      |> Enum.map(fn ({name, records}) -> deserialize(name, records) end)

    flags = attach_created_at_timestamps(repo, flags)
    {:ok, flags}
  rescue
    e in [Ecto.QueryError] -> {:error, e}
  end


  @impl true
  def all_flag_names do
    query = from(r in Record, select: r.flag_name, distinct: true)
    strings = ecto_repo().all(query, @query_opts)
    atoms = Enum.map(strings, &String.to_atom(&1))
    {:ok, atoms}
  rescue
    e in [Ecto.QueryError] -> {:error, e}
  end


  defp deserialize(flag_name, records) do
    Serializer.deserialize_flag(flag_name, records)
  end


  defp mysql_lock!(repo) do
    result = Ecto.Adapters.SQL.query!(
      repo,
      "SELECT GET_LOCK('fun_with_flags_percentage_gate_upsert', #{@mysql_lock_timeout_s})"
    )

    %{rows: [[i]]} = result
    i == 1
  end


  defp mysql_unlock!(repo) do
    result = Ecto.Adapters.SQL.query!(
      repo,
      "SELECT RELEASE_LOCK('fun_with_flags_percentage_gate_upsert');"
    )

    %{rows: [[i]]} = result
    i == 1
  end


  # PostgreSQL UPSERTs require an explicit conflict target.
  # MySQL/SQLite3 UPSERTs don't need it.
  #
  defp upsert_options(repo, gate = %Gate{}) do
    options = [on_conflict: [set: [enabled: gate.enabled]]]

    case db_type(repo) do
      :postgres ->
        options ++ [conflict_target: [:flag_name, :gate_type, :target]]
      type when type in [:mysql, :sqlite] ->
        options
    end
  end

  defp db_type(repo) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres -> :postgres
      Ecto.Adapters.MySQL -> :mysql # legacy, Mariaex
      Ecto.Adapters.MyXQL -> :mysql # new in ecto_sql 3.1
      Ecto.Adapters.SQLite3 -> :sqlite
      other -> raise "Ecto adapter #{inspect(other)} is not supported"
    end
  end


  defp do_insert(repo, flag_name, changeset, options \\ []) do
    changeset
    |> repo.insert(options)
    |> handle_write(flag_name)
  end


  defp do_update(repo, flag_name, changeset, options \\ []) do
    changeset
    |> repo.update(options)
    |> handle_write(flag_name)
  end


  defp handle_write(result, flag_name) do
    case result do
      {:ok, %Record{}} ->
        set_created_at(flag_name)
        get(flag_name) # {:ok, flag}
      {:error, bad_changeset} ->
        {:error, bad_changeset.errors}
    end
  end


  @impl true
  def put_many(flag_gate_tuples) when is_list(flag_gate_tuples) do
    repo = ecto_repo()

    case repo.transaction(fn ->
      do_put_many(repo, flag_gate_tuples)
    end) do
      {:ok, flags} -> {:ok, flags}
      {:error, reason} -> {:error, reason}
    end
  end


  @impl true
  def clear_and_replace(flag_gate_tuples) when is_list(flag_gate_tuples) do
    repo = ecto_repo()

    case repo.transaction(fn ->
      # Delete all existing flags
      repo.delete_all(Record, @query_opts)

      # Import new flags
      do_put_many(repo, flag_gate_tuples)
    end) do
      {:ok, flags} -> {:ok, flags}
      {:error, reason} -> {:error, reason}
    end
  end


  defp do_put_many(repo, flag_gate_tuples) do
    # Convert gates to plain maps for insert_all
    # (Record.build returns changesets, but insert_all needs maps)
    records = Enum.flat_map(flag_gate_tuples, fn {flag_name, gates} ->
      Enum.map(gates, fn gate ->
        changeset = Record.build(flag_name, gate)
        changeset.changes
      end)
    end)

    # Bulk upsert with conflict resolution
    repo.insert_all(
      Record,
      records,
      [
        on_conflict: {:replace_all_except, [:id]},
        conflict_target: [:flag_name, :gate_type, :target]
      ] ++ @query_opts
    )

    # Set created_at for all imported flags (only if not already set)
    Enum.each(flag_gate_tuples, fn {name, _gates} ->
      set_created_at(name)
    end)

    # Convert back to Flag structs
    Enum.map(flag_gate_tuples, fn {name, gates} ->
      %FunWithFlags.Flag{name: name, gates: gates}
    end)
  end



  # --- created_at column support (backwards compatible) ---
  #
  # The created_at column is optional. If the user has run the migration,
  # we use it. If not, everything works as before — created_at is simply nil.
  # Detection is cached in :persistent_term so the check query runs at most once.

  defp has_created_at_column? do
    case :persistent_term.get(@created_at_key, :not_checked) do
      :not_checked ->
        result = detect_created_at_column()
        :persistent_term.put(@created_at_key, result)
        result
      val ->
        val
    end
  end

  defp detect_created_at_column do
    table = Record.__schema__(:source)
    repo = ecto_repo()

    case db_type(repo) do
      :postgres ->
        case Ecto.Adapters.SQL.query(repo,
          "SELECT column_name FROM information_schema.columns WHERE table_name = $1 AND column_name = 'created_at'",
          [table]
        ) do
          {:ok, %{num_rows: n}} when n > 0 -> true
          _ -> false
        end

      :mysql ->
        case Ecto.Adapters.SQL.query(repo,
          "SELECT column_name FROM information_schema.columns WHERE table_name = ? AND column_name = 'created_at'",
          [table]
        ) do
          {:ok, %{num_rows: n}} when n > 0 -> true
          _ -> false
        end

      :sqlite ->
        case Ecto.Adapters.SQL.query(repo, "PRAGMA table_info(#{table})", []) do
          {:ok, %{rows: rows}} ->
            Enum.any?(rows, fn row -> Enum.at(row, 1) == "created_at" end)
          _ ->
            false
        end
    end
  rescue
    _ -> false
  end

  # Only sets created_at for rows where it is NULL (i.e. first creation).
  defp set_created_at(flag_name) do
    if has_created_at_column?() do
      table = Record.__schema__(:source)
      name_string = to_string(flag_name)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      repo = ecto_repo()

      case db_type(repo) do
        :postgres ->
          Ecto.Adapters.SQL.query(repo,
            "UPDATE #{table} SET created_at = $1 WHERE flag_name = $2 AND created_at IS NULL",
            [now, name_string]
          )
        :mysql ->
          Ecto.Adapters.SQL.query(repo,
            "UPDATE #{table} SET created_at = ? WHERE flag_name = ? AND created_at IS NULL",
            [now, name_string]
          )
        :sqlite ->
          Ecto.Adapters.SQL.query(repo,
            "UPDATE #{table} SET created_at = ?1 WHERE flag_name = ?2 AND created_at IS NULL",
            [now, name_string]
          )
      end
    end
  rescue
    _ -> :ok
  end

  defp attach_created_at_timestamps(repo, flags) do
    if has_created_at_column?() do
      table = Record.__schema__(:source)

      case Ecto.Adapters.SQL.query(repo,
        "SELECT flag_name, MIN(created_at) FROM #{table} GROUP BY flag_name", []
      ) do
        {:ok, %{rows: rows}} ->
          timestamps = Map.new(rows, fn [name, ts] -> {name, ts} end)

          Enum.map(flags, fn flag ->
            case Map.get(timestamps, to_string(flag.name)) do
              nil -> flag
              ts -> %{flag | created_at: ts}
            end
          end)

        _ ->
          flags
      end
    else
      flags
    end
  rescue
    _ -> flags
  end

end

end # Code.ensure_loaded?
