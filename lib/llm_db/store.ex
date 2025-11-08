defmodule LLMDB.Store do
  @moduledoc """
  Manages persistent_term storage for LLM model snapshots with atomic swaps.

  Uses `:persistent_term` for fast, concurrent reads with atomic updates tracked by monotonic epochs.
  """

  @store_key :llm_db_store

  @doc """
  Reads the full store from persistent_term.

  ## Returns

  Map with `:snapshot`, `:epoch`, and `:opts` keys, or `nil` if not set.
  """
  @spec get() :: map() | nil
  def get do
    :persistent_term.get(@store_key, nil)
  end

  @doc """
  Returns the snapshot portion from the store.

  ## Returns

  The snapshot map or `nil` if not set.
  """
  @spec snapshot() :: map() | nil
  def snapshot do
    case get() do
      %{snapshot: snapshot} -> snapshot
      _ -> nil
    end
  end

  @doc """
  Returns the current epoch from the store.

  ## Returns

  Non-negative integer representing the current epoch, or `0` if not set.
  """
  @spec epoch() :: non_neg_integer()
  def epoch do
    case get() do
      %{epoch: epoch} -> epoch
      _ -> 0
    end
  end

  @doc """
  Returns the last load options from the store.

  ## Returns

  Keyword list of options used in the last load, or `[]` if not set.
  """
  @spec last_opts() :: keyword()
  def last_opts do
    case get() do
      %{opts: opts} -> opts
      _ -> []
    end
  end

  @doc """
  Atomically swaps the store with new snapshot and options.

  Creates a new epoch using a monotonic unique integer and stores the complete state.

  ## Parameters

  - `snapshot` - The snapshot map to store
  - `opts` - Keyword list of options to store

  ## Returns

  `:ok`
  """
  @spec put!(map(), keyword()) :: :ok
  def put!(snapshot, opts) do
    epoch = :erlang.unique_integer([:monotonic, :positive])
    store = %{snapshot: snapshot, epoch: epoch, opts: opts}
    :persistent_term.put(@store_key, store)
    :ok
  end

  @doc """
  Clears the persistent_term store.

  Primarily used for testing cleanup.

  ## Returns

  `:ok`
  """
  @spec clear!() :: :ok
  def clear! do
    :persistent_term.erase(@store_key)
    :ok
  end

  # Query functions

  @doc """
  Returns all providers from the snapshot.

  ## Returns

  List of Provider structs, or empty list if no snapshot.
  """
  @spec providers() :: [LLMDB.Provider.t()]
  def providers do
    case snapshot() do
      %{providers: providers} when is_list(providers) ->
        Enum.map(providers, fn
          %LLMDB.Provider{} = p -> p
          provider -> LLMDB.Provider.new!(provider)
        end)

      _ ->
        []
    end
  end

  @doc """
  Returns a specific provider by ID.

  ## Parameters

  - `provider_id` - Provider atom

  ## Returns

  - `{:ok, provider}` - Provider found
  - `{:error, :not_found}` - Provider not found
  """
  @spec provider(atom()) :: {:ok, LLMDB.Provider.t()} | {:error, :not_found}
  def provider(provider_id) when is_atom(provider_id) do
    case snapshot() do
      %{providers_by_id: providers_by_id} ->
        case Map.get(providers_by_id, provider_id) do
          nil -> {:error, :not_found}
          provider -> {:ok, LLMDB.Provider.new!(provider)}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns all models for a specific provider.

  ## Parameters

  - `provider_id` - Provider atom

  ## Returns

  List of Model structs for the provider, or empty list if provider not found.
  """
  @spec models(atom()) :: [LLMDB.Model.t()]
  def models(provider_id) when is_atom(provider_id) do
    case snapshot() do
      %{models: models_by_provider} ->
        models_by_provider
        |> Map.get(provider_id, [])
        |> Enum.map(fn
          %LLMDB.Model{} = m -> m
          model -> LLMDB.Model.new!(model)
        end)

      _ ->
        []
    end
  end

  @doc """
  Returns a specific model by provider and ID.

  Resolves aliases to canonical model IDs.

  ## Parameters

  - `provider_id` - Provider atom
  - `model_id` - Model ID string (can be an alias)

  ## Returns

  - `{:ok, model}` - Model found
  - `{:error, :not_found}` - Model not found
  """
  @spec model(atom(), String.t()) :: {:ok, LLMDB.Model.t()} | {:error, :not_found}
  def model(provider_id, model_id) when is_atom(provider_id) and is_binary(model_id) do
    case snapshot() do
      %{models_by_key: models_by_key, aliases_by_key: aliases_by_key} ->
        key = {provider_id, model_id}

        # Try direct lookup first
        case Map.get(models_by_key, key) do
          nil ->
            # Try alias resolution
            case Map.get(aliases_by_key, key) do
              nil ->
                {:error, :not_found}

              canonical_id ->
                canonical_key = {provider_id, canonical_id}

                case Map.get(models_by_key, canonical_key) do
                  nil ->
                    {:error, :not_found}

                  %LLMDB.Model{} = m ->
                    {:ok, m}

                  model ->
                    {:ok, LLMDB.Model.new!(model)}
                end
            end

          %LLMDB.Model{} = m ->
            {:ok, m}

          model ->
            {:ok, LLMDB.Model.new!(model)}
        end

      _ ->
        {:error, :not_found}
    end
  end
end
