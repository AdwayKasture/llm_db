defmodule LLMDb do
  @moduledoc """
  Fast, persistent_term-backed LLM model metadata catalog.

  Provides a simple, capability-aware API for querying LLM model metadata.
  All queries are backed by `:persistent_term` for O(1), lock-free access.

  ## Two Phases

  **Phase 1 - Build Time** (Mix tasks):
  - `mix llm_db.pull` - Pull sources and run ETL pipeline to generate snapshot.json
  - This is a development/CI operation that builds the complete catalog

  **Phase 2 - Runtime** (Consumer library):
  - `load/1` - Load packaged snapshot into Store with optional filtering
  - Query functions to select models by capabilities
  - All queries operate on the filtered catalog loaded in Store

  ## Providers

  - `providers/0` - Get all providers as list of Provider structs
  - `provider/1` - Get a specific provider by ID

  ## Models

  - `models/0` - Get all models as list of Model structs
  - `models/1` - Get all models for a provider
  - `model/1` - Parse "provider:model" spec and get model
  - `model/2` - Get a specific model by provider and ID

  ## Selection and Policy

  - `select/1` - Select first model matching capability requirements
  - `candidates/1` - Get all models matching capability requirements
  - `allowed?/1` - Check if a model is in the filtered catalog
  - `capabilities/1` - Get capabilities map for a model

  ## Utilities

  - `parse/1` - Parse a model spec string into {provider, model_id} tuple

  ## Examples

      # Get all providers
      providers = LLMDb.providers()

      # Get a specific provider
      {:ok, provider} = LLMDb.provider(:openai)

      # Get all models for a provider
      models = LLMDb.models(:openai)

      # Get a specific model
      {:ok, model} = LLMDb.model(:openai, "gpt-4o-mini")

      # Parse spec and get model
      {:ok, model} = LLMDb.model("openai:gpt-4o-mini")

      # Select a model matching requirements
      {:ok, {:openai, "gpt-4o-mini"}} = LLMDb.select(
        require: [chat: true, tools: true, json_native: true],
        prefer: [:openai, :anthropic]
      )

      # Check if a model is allowed
      true = LLMDb.allowed?({:openai, "gpt-4o-mini"})
  """

  alias LLMDb.{Loader, Model, Provider, Query, Spec, Store}

  @type provider :: atom()
  @type model_id :: String.t()
  @type model_spec :: {provider(), model_id()} | String.t() | Model.t()

  # Lifecycle

  @doc """
  Loads or reloads the LLM model catalog.

  Phase 2 operation: Loads the packaged snapshot into runtime Store with
  optional filtering and customization based on consumer configuration.

  This function is idempotent - calling it multiple times with the same
  configuration will not reload the catalog unnecessarily.

  ## Options

  Consumer configuration options (override `config :llm_db, ...` settings):

  - `:allow` - `:all`, list of providers `[:openai]`, or map `%{openai: :all | [patterns]}`
  - `:deny` - List of providers `[:provider]` or map `%{provider: [patterns]}`
  - `:prefer` - List of provider atoms in preference order
  - `:custom` - Map with provider IDs as keys, provider configs (with models) as values

  ## Returns

  - `{:ok, snapshot}` - Successfully loaded the catalog
  - `{:error, :no_snapshot}` - No packaged snapshot available
  - `{:error, term}` - Other loading errors

  ## Examples

      # Load with default configuration from app env
      {:ok, _snapshot} = LLMDb.load()

      # Load with provider filter
      {:ok, _snapshot} = LLMDb.load(allow: [:openai, :anthropic])

      # Load with model pattern filters
      {:ok, _snapshot} = LLMDb.load(
        allow: %{openai: ["gpt-4*"], anthropic: :all},
        deny: %{openai: ["gpt-4-0613"]},
        prefer: [:anthropic, :openai]
      )

      # Load with custom providers/models
      {:ok, _snapshot} = LLMDb.load(
        custom: %{
          local: [
            name: "Local Provider",
            base_url: "http://localhost:8080",
            models: %{
              "llama-3" => %{capabilities: %{chat: true}},
              "mistral-7b" => %{capabilities: %{chat: true, tools: %{enabled: true}}}
            }
          ]
        }
      )
  """
  @spec load(keyword()) :: {:ok, map()} | {:error, term()}
  def load(opts \\ []) do
    case Loader.load(opts) do
      {:ok, snapshot} ->
        maybe_store_snapshot(snapshot, opts)

      {:error, :no_snapshot} ->
        load_empty(opts)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Loads an empty catalog with no providers or models.

  Used as a fallback when no packaged snapshot is available,
  allowing the application to start successfully. The catalog can
  later be populated via `load/1` once a snapshot is available.

  ## Examples

      LLMDb.load_empty()
      #=> {:ok, %{providers: [], models: %{}, ...}}
  """
  @spec load_empty(keyword()) :: {:ok, map()}
  def load_empty(opts \\ []) do
    {:ok, snapshot} = Loader.load_empty(opts)
    Store.put!(snapshot, opts)
    {:ok, snapshot}
  end

  # Providers

  @doc """
  Returns all providers as a list of Provider structs.

  ## Examples

      providers = LLMDb.providers()
      #=> [%LLMDb.Provider{id: :anthropic, ...}, ...]
  """
  @spec providers() :: [Provider.t()]
  defdelegate providers(), to: Store

  @doc """
  Returns a specific provider by ID.

  ## Parameters

  - `provider` - Provider atom (e.g., `:openai`, `:anthropic`)

  ## Returns

  - `{:ok, provider}` - Provider found
  - `{:error, term}` - Provider not found

  ## Examples

      {:ok, provider} = LLMDb.provider(:openai)
  """
  @spec provider(provider()) :: {:ok, Provider.t()} | {:error, term()}
  defdelegate provider(provider), to: Store

  # Models

  @doc """
  Returns all models across all providers (filtered).

  ## Examples

      models = LLMDb.models()
      #=> [%LLMDb.Model{}, ...]
  """
  @spec models() :: [Model.t()]
  def models do
    providers()
    |> Enum.flat_map(fn p -> Store.models(p.id) end)
  end

  @doc """
  Returns all models for a specific provider (filtered).

  ## Parameters

  - `provider` - Provider atom (e.g., `:openai`, `:anthropic`)

  ## Returns

  List of Model structs for the provider, or empty list if provider not found.

  ## Examples

      models = LLMDb.models(:openai)
      #=> [%LLMDb.Model{id: "gpt-4o", ...}, ...]
  """
  @spec models(provider()) :: [Model.t()]
  defdelegate models(provider), to: Store

  @doc """
  Parses "provider:model" spec string and returns the model.

  ## Parameters

  - `spec` - Model spec string like `"openai:gpt-4o-mini"`

  ## Returns

  - `{:ok, model}` - Model found
  - `{:error, term}` - Parse error or model not found

  ## Examples

      {:ok, model} = LLMDb.model("openai:gpt-4o-mini")
      {:ok, model} = LLMDb.model("anthropic:claude-3-5-sonnet-20241022")
  """
  @spec model(String.t()) :: {:ok, Model.t()} | {:error, term()}
  def model(spec) when is_binary(spec) do
    with {:ok, {p, id}} <- Spec.parse_spec(spec) do
      model(p, id)
    end
  end

  @doc """
  Returns a specific model by provider and ID (filtered).

  ## Parameters

  - `provider` - Provider atom (e.g., `:openai`)
  - `model_id` - Model ID string (e.g., `"gpt-4o-mini"`)

  ## Returns

  - `{:ok, model}` - Model found
  - `{:error, term}` - Model not found

  ## Examples

      {:ok, model} = LLMDb.model(:openai, "gpt-4o-mini")
  """
  @spec model(provider(), model_id()) :: {:ok, Model.t()} | {:error, term()}
  defdelegate model(provider, model_id), to: Store

  # Selection (delegated to Query)

  @doc """
  Selects the first model matching capability requirements.

  Delegates to `LLMDb.Query.select/1`.

  ## Options

  - `:require` - Keyword list of required capabilities
  - `:forbid` - Keyword list of forbidden capabilities
  - `:prefer` - List of provider atoms in preference order
  - `:scope` - Either `:all` (default) or a specific provider atom

  ## Returns

  - `{:ok, {provider, model_id}}` - First matching model
  - `{:error, :no_match}` - No models match the criteria

  ## Examples

      {:ok, {provider, model_id}} = LLMDb.select(
        require: [chat: true, tools: true],
        prefer: [:openai, :anthropic]
      )
  """
  @spec select(keyword()) :: {:ok, {provider(), model_id()}} | {:error, :no_match}
  def select(), do: Query.select([])
  defdelegate select(opts), to: Query

  @doc """
  Returns all models matching capability requirements.

  Delegates to `LLMDb.Query.candidates/1`.

  ## Options

  - `:require` - Keyword list of required capabilities
  - `:forbid` - Keyword list of forbidden capabilities
  - `:prefer` - List of provider atoms in preference order
  - `:scope` - Either `:all` (default) or a specific provider atom

  ## Returns

  List of `{provider, model_id}` tuples matching the criteria.

  ## Examples

      candidates = LLMDb.candidates(
        require: [chat: true, tools: true],
        prefer: [:openai, :anthropic]
      )
  """
  @spec candidates(keyword()) :: [{provider(), model_id()}]
  def candidates(), do: Query.candidates([])
  defdelegate candidates(opts), to: Query

  @doc """
  Gets capabilities for a model spec.

  Delegates to `LLMDb.Query.capabilities/1`.

  ## Parameters

  - `spec` - Either `{provider, model_id}` tuple, `"provider:model"` string, or `%Model{}` struct

  ## Examples

      caps = LLMDb.capabilities({:openai, "gpt-4o-mini"})
      #=> %{chat: true, tools: %{enabled: true, ...}, ...}
  """
  @spec capabilities(model_spec()) :: map() | nil
  defdelegate capabilities(spec), to: Query

  # Policy

  @doc """
  Returns true if the model is allowed by current filters.

  Checks if the model is present in the filtered snapshot loaded in Store.

  ## Parameters

  - `spec` - Either `%Model{}`, `{provider, model_id}` tuple, or `"provider:model"` string

  ## Returns

  `true` if model is in filtered catalog, `false` otherwise

  ## Examples

      true = LLMDb.allowed?({:openai, "gpt-4o-mini"})
      true = LLMDb.allowed?("openai:gpt-4o-mini")

      {:ok, model} = LLMDb.model(:openai, "gpt-4o-mini")
      true = LLMDb.allowed?(model)
  """
  @spec allowed?(model_spec()) :: boolean()
  def allowed?(%Model{provider: p, id: id}), do: allowed?({p, id})

  def allowed?({provider, model_id}) when is_atom(provider) and is_binary(model_id) do
    case Store.model(provider, model_id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def allowed?(spec) when is_binary(spec) do
    case Spec.parse_spec(spec) do
      {:ok, tuple} -> allowed?(tuple)
      _ -> false
    end
  end

  # Utilities

  @doc """
  Parses a model spec string into a {provider, model_id} tuple.

  Accepts either "provider:model" format or a {provider, model_id} tuple.

  ## Parameters

  - `spec` - Either a string like `"openai:gpt-4o-mini"` or tuple like `{:openai, "gpt-4o-mini"}`

  ## Returns

  - `{:ok, {provider, model_id}}` - Successfully parsed spec
  - `{:error, term}` - Invalid spec format

  ## Examples

      {:ok, {:openai, "gpt-4o-mini"}} = LLMDb.parse("openai:gpt-4o-mini")
      {:ok, {:anthropic, "claude-3-5-sonnet-20241022"}} = LLMDb.parse("anthropic:claude-3-5-sonnet-20241022")
      {:ok, {:openai, "gpt-4o"}} = LLMDb.parse({:openai, "gpt-4o"})
  """
  @spec parse(String.t() | {provider(), model_id()}) ::
          {:ok, {provider(), model_id()}} | {:error, term()}
  def parse(spec), do: Spec.parse_spec(spec)

  # Internal (Store access)

  @doc false
  @spec snapshot() :: map()
  defdelegate snapshot(), to: Store

  @doc false
  @spec epoch() :: non_neg_integer()
  defdelegate epoch(), to: Store

  # Private: idempotent storage - only update Store if snapshot changed
  defp maybe_store_snapshot(snapshot, opts) do
    prev = Store.snapshot()
    prev_digest = get_in(prev, [:meta, :digest])
    new_digest = get_in(snapshot, [:meta, :digest])

    if prev_digest == new_digest do
      {:ok, prev}
    else
      Store.put!(snapshot, opts)
      {:ok, snapshot}
    end
  end
end
