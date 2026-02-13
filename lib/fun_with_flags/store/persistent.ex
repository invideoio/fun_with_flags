defmodule FunWithFlags.Store.Persistent do
  @moduledoc """
  A behaviour module for implementing persistence adapters.

  The package ships with persistence adapters for Redis and Ecto, but you
  can provide your own adapters by adopting this behaviour.
  """

  @doc """
  A persistent adapter should return either
  [a child specification](https://hexdocs.pm/elixir/Supervisor.html#module-child-specification)
  if it needs any process to be started and supervised, or `nil` if it does not.

  For example, the builtin Redis persistence adapter implements this function by delegating to
  `Redix.child_spec/1` because it needs the Redix processes to work. On the other hand, the
  builtin Ecto adapter implements this function by returning `nil`, because the Ecto repo is
  provided to this package by the host application, and it's assumed that the Ecto process tree
  is started and supervised somewhere else.

  This custom `worker_spec/0` function is used instead of the typical `child_spec/1` function
  because this function can return `nil` if the adapter doesn't need to be supervised, whereas
  `child_spec/1` _must_ return a valid child spec map.
  """
  @callback worker_spec() ::
              Supervisor.child_spec
              | nil


  @doc """
  Retrieves a flag by name.
  """
  @callback get(flag_name :: atom) ::
              {:ok, FunWithFlags.Flag.t}
              | {:error, any()}

  @doc """
  Persists a gate for a flag, identified by name.
  """
  @callback put(flag_name :: atom, gate :: FunWithFlags.Gate.t) ::
              {:ok, FunWithFlags.Flag.t}
              | {:error, any()}

  @doc """
  Deletes a gate from a flag, identified by name.
  """
  @callback delete(flag_name :: atom, gate :: FunWithFlags.Gate.t) ::
              {:ok, FunWithFlags.Flag.t}
              | {:error, any()}


  @doc """
  Deletes an entire flag, identified by name.
  """
  @callback delete(flag_name :: atom) ::
              {:ok, FunWithFlags.Flag.t}
              | {:error, any()}


  @doc """
  Retrieves all the persisted flags.
  """
  @callback all_flags() ::
              {:ok, [FunWithFlags.Flag.t]}
              | {:error, any()}

  @doc """
  Retrieves all the names of the persisted flags.
  """
  @callback all_flag_names() ::
              {:ok, [atom]}
              | {:error, any()}

  @doc """
  Persists multiple flags, overwriting any that already exist.

  Takes a list of tuples where each tuple contains a flag name (atom) and
  a list of gates for that flag. Existing flags with the same names will
  be overwritten.

  Returns `{:ok, [Flag.t()]}` on success or `{:error, reason}` on failure.
  """
  @callback put_many([{flag_name :: atom(), [FunWithFlags.Gate.t]}]) ::
              {:ok, [FunWithFlags.Flag.t]} | {:error, any()}

  @doc """
  Atomically deletes all existing flags and replaces them with new ones.

  This is a destructive operation: all existing flags are removed, then the
  provided flags are inserted. The entire operation is atomic — if any part
  fails, no changes are committed.

  Returns `{:ok, [Flag.t()]}` on success or `{:error, reason}` on failure.
  """
  @callback clear_and_replace([{flag_name :: atom(), [FunWithFlags.Gate.t]}]) ::
              {:ok, [FunWithFlags.Flag.t]} | {:error, any()}
end
