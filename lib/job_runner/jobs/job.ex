defmodule JobRunner.Jobs.Job do
  @moduledoc """
  The record of one unit of work, and the only thing the system claims as truth.

  ## Why `attempts` and `attempt_id` are two different fields

    * `attempts` is the **budget counter** — how many attempts this job has spent
      against `max_attempts`. It stops the job retrying forever.

    * `attempt_id` is the **generation token** — a monotonic counter bumped on
      *every* dispatch, used to decide whether a message arriving now refers to
      the attempt currently running.

  They diverge precisely where it matters. When a Queue crash interrupts a
  running job, the interrupted attempt does **not** consume budget, so
  `attempts` stays put — but the next dispatch must still be distinguishable from
  the interrupted one, so `attempt_id` increments anyway. Collapsing these into
  one field reintroduces the stale-message bug: a late result from the killed
  attempt would carry a token that matches the new attempt and be accepted.

  ## Status

  Exactly the four the brief names. A job waiting out its backoff is `:pending`
  with `next_run_at` in the future; `retrying?/1` derives that for
  display without inventing a fifth status.
  """

  alias JobRunner.LLM

  @type status :: :pending | :running | :completed | :failed
  @type priority :: :high | :normal | :low

  @typedoc """
  One entry per attempt, newest first. This is what makes a dead-lettered job
  diagnosable rather than just "it failed".
  """
  @type attempt :: %{
          attempt_id: pos_integer(),
          attempt_no: non_neg_integer(),
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil,
          outcome: :ok | :error | :interrupted,
          error: LLM.Error.t() | map() | nil,
          backoff_ms: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          type: atom(),
          prompt: String.t(),
          priority: priority(),
          status: status(),
          attempts: non_neg_integer(),
          attempt_id: non_neg_integer(),
          max_attempts: pos_integer(),
          result: term() | nil,
          error: term() | nil,
          history: [attempt()],
          inserted_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          next_run_at: DateTime.t() | nil,
          dead_lettered_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :type, :prompt, :priority, :status, :max_attempts, :inserted_at]
  defstruct [
    :id,
    :type,
    :prompt,
    :priority,
    :result,
    :error,
    :inserted_at,
    :started_at,
    :finished_at,
    :next_run_at,
    :dead_lettered_at,
    :max_attempts,
    status: :pending,
    attempts: 0,
    attempt_id: 0,
    history: []
  ]

  @doc """
  Build a job from user input.

  Validation happens here, at admission, rather than at dispatch.
  """
  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    with {:ok, prompt} <- validate_prompt(attrs[:prompt] || attrs["prompt"]),
         {:ok, priority} <- validate_priority(attrs[:priority] || attrs["priority"] || :normal),
         {:ok, type} <- validate_type(attrs[:type] || attrs["type"] || :echo),
         {:ok, max_attempts} <-
           validate_max_attempts(attrs[:max_attempts] || config(:max_attempts, 5)) do
      {:ok,
       %__MODULE__{
         id: generate_id(),
         type: type,
         prompt: prompt,
         priority: priority,
         status: :pending,
         max_attempts: max_attempts,
         inserted_at: DateTime.utc_now()
       }}
    end
  end

  @doc "True when the job is waiting out a backoff rather than sitting fresh in the queue."
  @spec retrying?(t()) :: boolean()
  def retrying?(%__MODULE__{status: :pending, attempts: attempts, next_run_at: next})
      when attempts > 0 and not is_nil(next),
      do: true

  def retrying?(%__MODULE__{}), do: false

  @doc "True when no further attempt will be made without an explicit requeue."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :failed]

  @doc "True when the budget is spent and the next failure is terminal."
  @spec exhausted?(t()) :: boolean()
  def exhausted?(%__MODULE__{attempts: attempts, max_attempts: max}), do: attempts >= max

  @doc "Milliseconds until this job becomes runnable; 0 when it already is."
  @spec delay_until_runnable(t(), DateTime.t()) :: non_neg_integer()
  def delay_until_runnable(%__MODULE__{next_run_at: nil}, _now), do: 0

  def delay_until_runnable(%__MODULE__{next_run_at: next}, now) do
    next |> DateTime.diff(now, :millisecond) |> max(0)
  end

  defp validate_prompt(prompt) when is_binary(prompt) do
    trimmed = String.trim(prompt)

    cond do
      trimmed == "" ->
        {:error, :invalid_prompt}

      # Conservative byte cap that keeps us inside a 32k-token context window with room for the response.
      byte_size(trimmed) > config(:max_prompt_bytes, 24_000) ->
        {:error, :prompt_too_large}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_prompt(_), do: {:error, :invalid_prompt}

  # An unknown type can never succeed, so it is rejected at admission rather
  # than becoming a job that burns its budget failing identically five times.
  defp validate_type(type) when is_atom(type) do
    case JobRunner.Jobs.JobType.fetch(type) do
      {:ok, _module} -> {:ok, type}
      {:error, :unknown_type} -> {:error, :unknown_type}
    end
  end

  defp validate_type(type) when is_binary(type) do
    validate_type(String.to_existing_atom(type))
  rescue
    ArgumentError -> {:error, :unknown_type}
  end

  defp validate_type(_), do: {:error, :unknown_type}

  # Ensure max attempts is non zero and non-negative
  defp validate_max_attempts(value) when is_integer(value) and value >= 1 and value <= 10,
    do: {:ok, value}

  defp validate_max_attempts(_), do: {:error, :invalid_max_attempts}

  defp validate_priority(priority) when priority in [:high, :normal, :low], do: {:ok, priority}
  defp validate_priority("high"), do: {:ok, :high}
  defp validate_priority("normal"), do: {:ok, :normal}
  defp validate_priority("low"), do: {:ok, :low}
  defp validate_priority(_), do: {:error, :invalid_priority}

  # Randomly generated Id String
  defp generate_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp config(key, default) do
    :job_runner |> Application.get_env(:jobs, []) |> Keyword.get(key, default)
  end
end
