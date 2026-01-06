defmodule Mix.Tasks.LlmDb.Install.Docs do
  @moduledoc false

  @spec short_doc() :: String.t()
  def short_doc do
    "Install and configure LLM DB in your application"
  end

  @spec example() :: String.t()
  def example do
    "mix llm_db.install"
  end

  @spec long_doc() :: String.t()
  def long_doc do
    """
    #{short_doc()}

    Installs LLM DB into your application by adding the dependency and
    configuring basic settings. This sets up the LLM model metadata catalog
    with fast capability-aware lookups.

    ## Example

    ```sh
    #{example()}
    ```

    ## What it does

    * Adds `llm_db` to your dependencies in `mix.exs`
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.LlmDb.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :llm_db,
        adds_deps: [],
        installs: [],
        example: __MODULE__.Docs.example(),
        only: nil,
        positional: [],
        composes: [],
        schema: [],
        defaults: [],
        aliases: [],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> Igniter.add_notice("""
      LLM DB installed successfully!

      Next steps: 

      Try running the command:
      mix llm_db.models                    # List all available models

      To get started quickly:
      https://hexdocs.pm/llm_db/readme.html#quick-start

      Guides and recipes:
      https://hexdocs.pm/llm_db/readme.html#docs-guides
      """)
    end
  end
else
  defmodule Mix.Tasks.LlmDb.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'llm_db.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
