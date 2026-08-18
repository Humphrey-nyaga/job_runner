defmodule JobRunner.Jobs.JobType.Summarize do
  @moduledoc """
  Ask for structured JSON — a summary and a category — and validate it.

  This is the job type that makes the retry machinery earn its keep against a
  *non-deterministic* failure mode. An LLM asked for JSON will occasionally
  return prose, a fenced code block, valid JSON with the wrong keys, or a
  category outside the allowed set. None of those are endpoint failures, and all
  of them are worth one more sample.

  ## Validation is a whitelist, not a vibe check

  `@categories` is closed. A model returning `"miscellaneous"` when the options
  are finance/technical/legal/other is a failed attempt, not a new category — if
  it were accepted, downstream consumers would have to handle an open-ended set
  and the structure would be structure in name only.
  """

  @behaviour JobRunner.Jobs.JobType

  alias JobRunner.Jobs.{Job, JobType}
  alias JobRunner.LLM

  # Declared as atoms, not strings, and matched by lookup rather than by
  # `String.to_existing_atom/1`.
  #
  # `String.to_existing_atom/1` on a model-supplied string is unsafe here: the
  # atom only exists if something else happened to create it, which is a
  # property of the whole build rather than of this module. Declaring the atoms
  # means they exist because this module exists, and the string mapping is total
  # by construction.
  @categories [:finance, :technical, :legal, :other]
  @category_strings Map.new(@categories, &{Atom.to_string(&1), &1})

  @system """
  You summarise text and classify it.

  Respond with a single JSON object and nothing else. No prose, no code fence.

  Schema:
    {"summary": "<one sentence, at most 30 words>",
     "category": "<one of: #{Enum.map_join(@categories, ", ", &Atom.to_string/1)}>"}
  """

  @impl true
  def messages(%Job{prompt: prompt}) do
    LLM.messages("Summarise and classify the following:\n\n#{prompt}", @system)
  end

  @impl true
  def parse(text) do
    with {:ok, object} <- JobType.extract_json(text),
         {:ok, summary} <- validate_summary(object),
         {:ok, category} <- validate_category(object) do
      {:ok, %{summary: summary, category: category}}
    end
  end

  @impl true
  def llm_opts do
    # Ask the provider to constrain output to JSON where it supports it. This is
    # a hint, not a guarantee — vLLM and older servers ignore it — so `parse/1`
    # still validates everything. Belt and braces, because the belt is optional.
    [response_format: %{type: "json_object"}]
  end

  defp validate_summary(%{"summary" => summary}) when is_binary(summary) do
    case String.trim(summary) do
      "" -> {:error, {:invalid_shape, "summary was empty"}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_summary(%{"summary" => _}),
    do: {:error, {:invalid_shape, "summary was not a string"}}

  defp validate_summary(_), do: {:error, {:invalid_shape, "missing key: summary"}}

  defp validate_category(%{"category" => category}) when is_binary(category) do
    normalised = category |> String.trim() |> String.downcase()

    case Map.fetch(@category_strings, normalised) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error, {:invalid_shape, "category #{inspect(category)} not in #{inspect(@categories)}"}}
    end
  end

  defp validate_category(_), do: {:error, {:invalid_shape, "missing key: category"}}

  @doc "The closed set of categories. Exposed for the dashboard and tests."
  @spec categories() :: [atom()]
  def categories, do: @categories
end
