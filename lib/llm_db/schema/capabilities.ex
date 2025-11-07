defmodule LLMDb.Schema.Capabilities do
  @moduledoc """
  Zoi schema for LLM model capabilities.

  Defines model capabilities including chat, embeddings, reasoning, tools,
  JSON support, and streaming. Provides sensible defaults for common scenarios.
  """

  @reasoning_schema Zoi.object(%{
                      enabled: Zoi.boolean() |> Zoi.optional(),
                      token_budget: Zoi.integer() |> Zoi.min(0) |> Zoi.optional()
                    })

  @tools_schema Zoi.object(%{
                  enabled: Zoi.boolean() |> Zoi.optional(),
                  streaming: Zoi.boolean() |> Zoi.optional(),
                  strict: Zoi.boolean() |> Zoi.optional(),
                  parallel: Zoi.boolean() |> Zoi.optional()
                })

  @json_schema Zoi.object(%{
                 native: Zoi.boolean() |> Zoi.optional(),
                 schema: Zoi.boolean() |> Zoi.optional(),
                 strict: Zoi.boolean() |> Zoi.optional()
               })

  @streaming_schema Zoi.object(%{
                      text: Zoi.boolean() |> Zoi.optional(),
                      tool_calls: Zoi.boolean() |> Zoi.optional()
                    })

  @embeddings_schema Zoi.object(%{
                       min_dimensions: Zoi.integer() |> Zoi.min(1) |> Zoi.optional(),
                       max_dimensions: Zoi.integer() |> Zoi.min(1) |> Zoi.optional(),
                       default_dimensions: Zoi.integer() |> Zoi.min(1) |> Zoi.optional()
                     })

  @schema Zoi.object(%{
            chat: Zoi.boolean() |> Zoi.default(true),
            embeddings: Zoi.union([Zoi.boolean(), @embeddings_schema]) |> Zoi.default(false),
            reasoning: @reasoning_schema |> Zoi.default(%{enabled: false}),
            tools:
              @tools_schema
              |> Zoi.default(%{enabled: false, streaming: false, strict: false, parallel: false}),
            json: @json_schema |> Zoi.default(%{native: false, schema: false, strict: false}),
            streaming: @streaming_schema |> Zoi.default(%{text: true, tool_calls: false})
          })

  @type t :: unquote(Zoi.type_spec(@schema))

  @doc "Returns the Zoi schema for Capabilities"
  def schema, do: @schema
end
