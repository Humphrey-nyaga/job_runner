defmodule JobRunner.Jobs do
  @moduledoc """
  Public API of the job system.

  Callers never learn the internal shape — that a Queue process exists, that
  state lives in ETS, or which provider is configured.

  Writes go through the Store's serialised write path and then notify the Queue.
  Reads hit ETS directly with no message to any process, so status polling never
  queues behind dispatch.
  """

  alias JobRunner.Jobs.{Job, Queue, Store}

  @type id :: String.t()

  @doc """
  Submit a job. Accepts a bare prompt, or a map with `:type` and `:priority`.

      add_job("summarise this")
      add_job(%{prompt: "urgent thing", priority: :high})

  Validated at admission rather than at dispatch, so a prompt that can never
  succeed is rejected while the caller still holds the return value. Errors:
  `:invalid_prompt`, `:prompt_too_large`, `:invalid_priority`,
  `:invalid_max_attempts`, `:unknown_type`, `:queue_full`.
  """
  @spec add_job(String.t() | map()) :: {:ok, id()} | {:error, atom()}
  def add_job(prompt) when is_binary(prompt), do: add_job(%{prompt: prompt})

  def add_job(attrs) when is_map(attrs) do
    with {:ok, job} <- Job.new(attrs),
         {:ok, job} <- Store.insert(job) do
      # Store first, then notify. The Queue is a scheduler, not a record-keeper:
      # if this cast were lost, reconciliation would still find the job.
      :ok = Queue.enqueue(job)
      {:ok, job.id}
    end
  end

  @doc """
  Current status: `:pending`, `:running`, `:completed` or `:failed`.

  A job waiting out a backoff reports `:pending` — use `fetch/1` and
  `Job.retrying?/1` if you need to distinguish the two for display.
  """
  @spec status(id()) :: {:ok, Job.status()} | {:error, :not_found}
  def status(job_id) do
    with {:ok, job} <- Store.fetch(job_id), do: {:ok, job.status}
  end

  @doc """
  The result of a completed job.

  Returns `{:error, :not_completed}` while the job is still in play, rather than
  `nil` — an absent result and a result of `nil` are different facts.
  """
  @spec result(id()) :: {:ok, term()} | {:error, :not_found | :not_completed}
  def result(job_id) do
    case Store.fetch(job_id) do
      {:ok, %Job{status: :completed, result: result}} -> {:ok, result}
      {:ok, %Job{}} -> {:error, :not_completed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The whole job record, including attempt history."
  @spec fetch(id()) :: {:ok, Job.t()} | {:error, :not_found}
  defdelegate fetch(job_id), to: Store

  @doc "All jobs, newest first."
  @spec all() :: [Job.t()]
  defdelegate all(), to: Store

  @doc "Jobs that exhausted their budget or failed permanently, with full history."
  @spec dead_letters() :: [Job.t()]
  defdelegate dead_letters(), to: Store

  @doc """
  Replay a dead-lettered job with a fresh attempt budget.

  Deliberately manual: an automatic DLQ drain is how a retry storm becomes an
  infinite retry storm.
  """
  @spec requeue(id()) :: {:ok, id()} | {:error, :not_found | :not_dead_lettered}
  def requeue(job_id) do
    with {:ok, job} <- Store.requeue(job_id) do
      :ok = Queue.enqueue(job)
      {:ok, job.id}
    end
  end

  @doc """
  Current circuit breaker state.

  Worth surfacing publicly: when the breaker is open the system is deliberately
  idle, and "why is nothing running?" should have a visible answer rather than
  looking like a hang.
  """
  @spec breaker() :: JobRunner.Jobs.Breaker.t()
  defdelegate breaker(), to: Store

  @doc """
  Cumulative counters: jobs enqueued, started, succeeded, failed, retried,
  dead-lettered, requeued, crashed, timed out, plus breaker trips.

  These count **events over time** and never decrease. Current state — how many
  jobs are pending right now — comes from `stats/0`, which asks the Store.
  Keeping the two apart avoids a gauge that drifts out of sync after a restart.
  """
  @spec metrics() :: map()
  defdelegate metrics(), to: JobRunner.Jobs.Metrics, as: :summary

  @doc "Counts by status, queue depths, live task count, and breaker state."
  @spec stats() :: map()
  def stats do
    breaker = Store.breaker()
    pending = Store.pending_breakdown()
    depths = Queue.queue_depths()

    Store.count_by_status()
    |> Map.put(:in_flight, Queue.in_flight_count())
    |> Map.put(:queued, depths)
    # `:queued` is the Queue's own FIFO lengths; `:runnable` and `:scheduled`
    # come from the Store. They are reported separately because a pending job
    # awaiting a backoff is deliberately NOT in a FIFO, so the two
    # numbers legitimately differ — and only showing the FIFO lengths makes a
    # retry storm look like an empty queue.
    |> Map.put(:runnable, pending.runnable)
    |> Map.put(:scheduled, pending.scheduled)
    |> Map.put(:queue_depth, depths.high + depths.normal + depths.low)
    |> Map.put(:dead_lettered, length(Store.dead_letters()))
    |> Map.put(:breaker, breaker.state)
    |> Map.put(:breaker_failures, breaker.failures)
    # Surfaced alongside the live count so "4 in flight" reads as "4 of 4",
    # i.e. saturated and working, rather than as an unexplained number. Asked of
    # the Queue rather than of config, because the Queue may have been started
    # with an explicit limit and config would then be reporting a number nothing
    # is actually enforcing.
    |> Map.put(:in_flight_limit, Queue.max_concurrency())
  end

  @doc "Subscribe the calling process to `{:job_updated, job}` broadcasts."
  @spec subscribe() :: :ok | {:error, term()}
  defdelegate subscribe(), to: Store
end
