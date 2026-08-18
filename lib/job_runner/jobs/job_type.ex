defmodule JobRunner.Jobs.JobType do
  @moduledoc """
  What a job actually *asks the model for*, and what counts as a usable answer.

  Splitting this out from the Worker keeps the engine indifferent to content. The
  Queue schedules, retries and gives up; it has no opinion about prompts or
  result shapes. Adding a new kind of job is a new module implementing this
  behaviour — no change to the scheduler, the Store, or the adapter.

  ## Why `parse/1` is part of the contract

  A 200 response with unusable content is a **failure**, and one worth retrying:
  the endpoint is healthy, the sample was bad, and resampling a
  non-deterministic generator is a perfectly reasonable response. Making parsing
  part of the job type is what lets that failure re-enter the same retry and
  backoff machinery as an HTTP 503, rather than being special-cased.

  Errors returned from `parse/1` land in `JobRunner.Jobs.Failure` as
  `:retryable` but **not** `:systemic` — a model returning bad JSON says nothing
  about whether the endpoint is healthy, so it must never trip the circuit
  breaker.
  """

  alias JobRunner.Jobs.Job
  alias JobRunner.LLM

  @doc "The messages to send for this job."
  @callback messages(Job.t()) :: [LLM.message()]

  @doc """
  Turn the model's raw text into a result, or reject it.

  Rejections should be `{:invalid_json, reason}` or `{:invalid_shape, reason}`
  so they classify correctly.

  A type may also return `{:tool_call, name}` to ask the Worker to run a local
  tool and try again with the result (see `JobRunner.Jobs.Tools`). The Worker
  permits exactly one such round per attempt.
  """
  @callback parse(String.t()) ::
              {:ok, term()} | {:tool_call, String.t()} | {:error, term()}

  @doc "Per-type adapter options, merged over the configured defaults."
  @callback llm_opts() :: keyword()

  @optional_callbacks llm_opts: 0

  @types %{
    echo: JobRunner.Jobs.JobType.Echo,
    summarize: JobRunner.Jobs.JobType.Summarize,
    assisted: JobRunner.Jobs.JobType.Assisted
  }

  @doc "Resolve a job type name to its module."
  @spec fetch(atom()) :: {:ok, module()} | {:error, :unknown_type}
  def fetch(name) do
    case Map.fetch(@types, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_type}
    end
  end

  @doc "Every registered type name. Used by the dashboard's submit form."
  @spec names() :: [atom()]
  def names, do: Map.keys(@types)

  @doc """
  Pull a JSON object out of a model response.

  Models routinely wrap JSON in prose or a ```json fence even when told not to.
  Being tolerant here is not sloppiness — it is the difference between a retry
  that costs a second call and one that succeeds immediately. We still reject
  anything that is not actually a JSON object, so tolerance never becomes
  guessing.
  """
  @spec extract_json(String.t()) :: {:ok, map()} | {:error, term()}
  def extract_json(text) do
    text
    |> strip_fence()
    |> Jason.decode()
    |> case do
      {:ok, %{} = object} -> {:ok, object}
      {:ok, other} -> {:error, {:invalid_shape, "expected a JSON object, got #{type_of(other)}"}}
      {:error, %Jason.DecodeError{}} -> try_embedded(text)
    end
  end

  defp strip_fence(text) do
    text
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*/, "")
    |> String.replace(~r/```\z/, "")
    |> String.trim()
  end

  # Last resort: the model wrote a sentence and then the JSON. Take the first
  # plausible object rather than failing the whole attempt.
  #
  # Both a greedy and a lazy match are tried: greedy first because a single
  # nested object is the common case and lazy would stop at the first inner `}`;
  # lazy second because with two sibling objects greedy spans from the first `{`
  # to the last `}` and captures neither.
  defp try_embedded(text) do
    candidates =
      [~r/\{.*\}/s, ~r/\{.*?\}/s]
      |> Enum.flat_map(fn re -> Regex.run(re, text) || [] end)

    case Enum.find_value(candidates, fn candidate ->
           case Jason.decode(candidate) do
             {:ok, %{} = object} -> object
             _ -> nil
           end
         end) do
      nil -> {:error, {:invalid_json, truncate(text)}}
      object -> {:ok, object}
    end
  end

  defp type_of(value) when is_list(value), do: "a list"
  defp type_of(value) when is_binary(value), do: "a string"
  defp type_of(value) when is_number(value), do: "a number"
  defp type_of(_), do: "something else"

  # Errors are stored and broadcast, so they stay bounded.
  defp truncate(text) when byte_size(text) <= 100, do: text
  defp truncate(text), do: String.slice(text, 0, 100) <> "…"
end
