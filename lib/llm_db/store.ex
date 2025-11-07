defmodule LLMDb.Store do
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
  @spec providers() :: [LLMDb.Provider.t()]
  def providers do
    case snapshot() do
      %{providers: providers} when is_list(providers) ->
        Enum.map(providers, fn
          %LLMDb.Provider{} = p -> p
          provider -> provider |> normalize_provider_for_struct() |> LLMDb.Provider.new!()
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
  @spec provider(atom()) :: {:ok, LLMDb.Provider.t()} | {:error, :not_found}
  def provider(provider_id) when is_atom(provider_id) do
    case snapshot() do
      %{providers_by_id: providers_by_id} ->
        case Map.get(providers_by_id, provider_id) do
          nil -> {:error, :not_found}
          provider -> {:ok, LLMDb.Provider.new!(provider)}
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
  @spec models(atom()) :: [LLMDb.Model.t()]
  def models(provider_id) when is_atom(provider_id) do
    case snapshot() do
      %{models: models_by_provider} ->
        models_by_provider
        |> Map.get(provider_id, [])
        |> Enum.map(fn
          %LLMDb.Model{} = m -> m
          model -> model |> normalize_model_for_struct() |> LLMDb.Model.new!()
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
  @spec model(atom(), String.t()) :: {:ok, LLMDb.Model.t()} | {:error, :not_found}
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

                  %LLMDb.Model{} = m ->
                    {:ok, m}

                  model ->
                    {:ok, model |> normalize_model_for_struct() |> LLMDb.Model.new!()}
                end
            end

          %LLMDb.Model{} = m ->
            {:ok, m}

          model ->
            {:ok, model |> normalize_model_for_struct() |> LLMDb.Model.new!()}
        end

      _ ->
        {:error, :not_found}
    end
  end

  # Private helpers to normalize data before converting to structs
  # Handles cases where snapshot data has incompatible types or nil values

  defp normalize_provider_for_struct(%LLMDb.Provider{} = provider) do
    # Already a Provider struct, return as-is
    provider
  end

  defp normalize_provider_for_struct(provider) when is_map(provider) do
    # Remove nil values - Zoi handles missing optional fields better than explicit nils
    provider
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_model_for_struct(%LLMDb.Model{} = model) do
    # Already a Model struct, return as-is
    model
  end

  defp normalize_model_for_struct(model) when is_map(model) do
    model
    |> normalize_tags()
    |> normalize_dates()
    # Remove ALL nil values at the end - Zoi handles missing optional fields better
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_tags(model) do
    case Map.get(model, :tags) do
      tags when is_map(tags) and map_size(tags) > 0 ->
        Map.put(model, :tags, Map.values(tags))

      tags when is_map(tags) ->
        Map.put(model, :tags, [])

      nil ->
        # Don't add empty array, let remove_nil_values handle it
        model

      tags when is_list(tags) ->
        model

      _ ->
        model
    end
  end

  defp normalize_dates(model) do
    model
    |> normalize_date_field(:last_updated)
    |> normalize_date_field(:knowledge)
  end

  defp normalize_date_field(model, field) do
    if Map.has_key?(model, field) do
      case Map.get(model, field) do
        %DateTime{} = dt ->
          Map.put(model, field, DateTime.to_iso8601(dt))

        %Date{} = d ->
          Map.put(model, field, Date.to_iso8601(d))

        nil ->
          # Keep nil, will be removed by final reject
          model

        value when is_binary(value) ->
          model

        _ ->
          # Remove invalid values
          Map.delete(model, field)
      end
    else
      model
    end
  end
end
