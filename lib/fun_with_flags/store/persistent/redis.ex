if Code.ensure_loaded?(Redix) do

defmodule FunWithFlags.Store.Persistent.Redis do
  @moduledoc false

  @behaviour FunWithFlags.Store.Persistent

  alias FunWithFlags.{Config, Gate}
  alias FunWithFlags.Store.Serializer.Redis, as: Serializer

  @conn __MODULE__
  @conn_options [name: @conn, sync_connect: false]
  @prefix "fun_with_flags:"
  @flags_set "fun_with_flags"


  # Retrieve the configuration to connect to Redis, and package it as an argument
  # to be passed to the start_link function.
  #
  @impl true
  def worker_spec do
    conf = case Config.redis_config do
      uri when is_binary(uri) ->
        {uri, @conn_options}
      {uri, opts} when is_binary(uri) and is_list(opts) ->
        {uri, Keyword.merge(opts, @conn_options)}
      opts when is_list(opts) ->
        Keyword.merge(opts, @conn_options)
    end

    Redix.child_spec(conf)
  end


  @impl true
  def get(flag_name) do
    case Redix.command(@conn, ["HGETALL", format(flag_name)]) do
      {:ok, data}   -> {:ok, Serializer.deserialize_flag(flag_name, data)}
      {:error, why} -> {:error, redis_error(why)}
    end
  end


  @impl true
  def put(flag_name, gate = %Gate{}) do
    data = Serializer.serialize(gate)

    result = Redix.pipeline(@conn, [
      ["MULTI"],
      ["SADD", @flags_set, flag_name],
      ["HSET" | [format(flag_name) | data]],
      ["EXEC"]
    ])

    case result do
      {:ok, ["OK", "QUEUED", "QUEUED", [a, b]]} when a in [0, 1] and b in [0, 1] ->
        {:ok, flag} = get(flag_name)
        {:ok, flag}
      {:error, reason} ->
        {:error, redis_error(reason)}
      {:ok, results} ->
        {:error, redis_error("one of the commands failed: #{inspect(results)}")}
    end
  end


  # Deletes one gate from the Flag's Redis hash.
  # Deleting gates is idempotent and deleting unknown gates is safe.
  # A flag will continue to exist even though it has no gates.
  #
  @impl true
  def delete(flag_name, gate = %Gate{}) do
    hash_key = format(flag_name)
    [field_key, _] = Serializer.serialize(gate)

    case Redix.command(@conn, ["HDEL", hash_key, field_key]) do
      {:ok, _number} ->
        {:ok, flag} = get(flag_name)
        {:ok, flag}
      {:error, reason} ->
        {:error, redis_error(reason)}
    end
  end


  # Deletes an entire Flag's Redis hash and removes its name from the Redis set.
  # Deleting flags is idempotent and deleting unknown flags is safe.
  # After the operation fetching the now-deleted flag will return the default
  # empty flag structure.
  #
  @impl true
  def delete(flag_name) do
    result = Redix.pipeline(@conn, [
      ["MULTI"],
      ["SREM", @flags_set, flag_name],
      ["DEL", format(flag_name)],
      ["EXEC"]
    ])

    case result do
      {:ok, ["OK", "QUEUED", "QUEUED", [a, b]]} when a in [0, 1] and b in [0, 1] ->
        {:ok, flag} = get(flag_name)
        {:ok, flag}
      {:error, reason} ->
        {:error, redis_error(reason)}
      {:ok, results} ->
        {:error, redis_error("one of the commands failed: #{inspect(results)}")}
    end
  end


  @impl true
  def all_flags do
    case all_flag_names() do
      {:ok, flag_names} -> materialize_flags_from_names(flag_names)
      error -> error
    end
  end

  defp materialize_flags_from_names(flag_names) do
    flags = Enum.map(flag_names, fn(name) ->
      case get(name) do
        {:ok, flag} -> flag
        error -> error
      end
    end)
    {:ok, flags}
  end


  @impl true
  def all_flag_names do
    case Redix.command(@conn, ["SMEMBERS", @flags_set]) do
      {:ok, strings} ->
        atoms = Enum.map(strings, &String.to_atom(&1))
        {:ok, atoms}
      {:error, reason} ->
        {:error, redis_error(reason)}
    end
  end


  defp format(flag_name) do
    @prefix <> to_string(flag_name)
  end

  defp redis_error(%Redix.ConnectionError{reason: reason_atom}) do
    "Redis Connection Error: #{reason_atom}"
  end

  defp redis_error(%Redix.Error{message: message}) do
    "Redis Error: #{message}"
  end

  defp redis_error(reason_atom) do
    "Redis Error: #{reason_atom}"
  end


  @impl true
  def put_many(flag_gate_tuples) when is_list(flag_gate_tuples) do
    commands = [["MULTI"]] ++ build_put_many_commands(flag_gate_tuples) ++ [["EXEC"]]
    exec_transaction(commands, flag_gate_tuples)
  end


  @impl true
  def clear_and_replace(flag_gate_tuples) when is_list(flag_gate_tuples) do
    # First, get existing flag names so we can delete their hashes
    case Redix.command(@conn, ["SMEMBERS", @flags_set]) do
      {:ok, existing_names} ->
        # Build a single MULTI/EXEC that deletes everything and inserts new data
        delete_commands = Enum.map(existing_names, fn name -> ["DEL", format(name)] end)

        commands =
          [["MULTI"]] ++
          [["DEL", @flags_set]] ++
          delete_commands ++
          build_put_many_commands(flag_gate_tuples) ++
          [["EXEC"]]

        exec_transaction(commands, flag_gate_tuples)

      {:error, reason} ->
        {:error, redis_error(reason)}
    end
  end


  defp build_put_many_commands(flag_gate_tuples) do
    Enum.flat_map(flag_gate_tuples, fn {flag_name, gates} ->
      flag_name_str = to_string(flag_name)
      serialized_data = Enum.flat_map(gates, &Serializer.serialize/1)

      # Always register the flag name and clear existing gates
      base = [
        ["SADD", @flags_set, flag_name_str],
        ["DEL", format(flag_name)]
      ]

      # Only HSET if there are gates (HSET with no fields is an error)
      if serialized_data != [] do
        base ++ [["HSET" | [format(flag_name) | serialized_data]]]
      else
        base
      end
    end)
  end


  defp exec_transaction(commands, flag_gate_tuples) do
    case Redix.pipeline(@conn, commands) do
      {:ok, results} ->
        # Last result is EXEC result
        case List.last(results) do
          result when is_list(result) ->
            flags = Enum.map(flag_gate_tuples, fn {name, gates} ->
              %FunWithFlags.Flag{name: name, gates: gates}
            end)
            {:ok, flags}
          error ->
            {:error, redis_error("EXEC failed: #{inspect(error)}")}
        end
      {:error, reason} ->
        {:error, redis_error(reason)}
    end
  end
end

end # Code.ensure_loaded?
