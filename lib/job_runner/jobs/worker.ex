defmodule JobRunner.Jobs.Worker do
  @moduledoc """
  Runs one job, one attempt, inside a supervised `Task`.

  Stateless and policy-free: the Queue owns retries and budgets, the JobType
  owns prompts and parsing, the adapter owns the wire protocol.

  Never sleeps and never retries — a worker that waited would hold its
  concurrency slot while doing nothing.

  A job type may return `{:tool_call, name}` from `parse/1`, in which case the
  Worker runs the named local function and re-prompts with the result. Exactly
  one such round is permitted, and both calls belong to the same attempt: if
  either fails, the attempt fails and the Queue restarts it from the beginning.
  """

  alias JobRunner.Jobs.{Job, JobType, Metrics, Tools}
  alias JobRunner.LLM

  require Logger

  @doc """
  Run one attempt: build the prompt, call the model, parse the answer, and take
  at most one tool round if the job type asks for one.

  Returns `{:ok, result}` or `{:error, reason}` — never raises for an anticipated
  failure. An exception escaping here is a genuine bug, and the Queue treats it
  as a crash, which is a much louder signal than a provider being
  unavailable.
  """
  @spec run(Job.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(%Job{} = job, opts \\ []) do
    with {:ok, type} <- JobType.fetch(job.type),
         {:ok, text} <- call(type, job, opts, type.messages(job)) do
      case type.parse(text) do
        {:tool_call, tool} -> tool_round(type, job, opts, tool, text)
        result -> result
      end
    end
  end

  defp tool_round(type, job, opts, tool, first_response) do
    Metrics.increment(:tool_calls)
    Logger.info("job #{job.id} requested tool #{tool}")

    with {:ok, tool_result} <- Tools.invoke(tool),
         messages = type.follow_up(job, tool, tool_result, first_response),
         {:ok, text} <- call(type, job, opts, messages) do
      case type.parse(text) do
        # The cap. A model that asks again gets a retryable error rather than a
        # third call, so the round count is bounded by construction.
        {:tool_call, again} ->
          {:error, {:invalid_shape, "asked for tool #{inspect(again)} after one round"}}

        result ->
          result
      end
    end
  end

  defp call(type, _job, opts, messages) do
    type
    |> job_opts()
    |> Keyword.merge(opts)
    |> then(&LLM.chat(messages, &1))
  end

  # A type may request adapter options — the structured types ask for JSON mode —
  # but they are merged *under* the caller's, so a test or the Queue can override.
  defp job_opts(type) do
    if function_exported?(type, :llm_opts, 0), do: type.llm_opts(), else: []
  end
end
