defmodule JobRunner.Jobs.Store do
  @moduledoc """
  Owns the ETS tables holding job state, and is the only process allowed to
  write to them.

  ## The asymmetry

  Tables are `:protected`, which means:

    * **any process may read directly** — `fetch/1`, `all/0` and the LiveView do
      plain `:ets.lookup/2` with no message to this process. Status queries never
      queue behind dispatch;
    * **only the owner may write** — so every state transition passes through
      the API below, where it is validated against the job's current status and
      current `attempt_id` before anything changes.

  That single serialisation point is what makes the attempt-token check enforceable. A stale
  result from a superseded attempt cannot overwrite a newer one, because the
  write is rejected here rather than depended on to never arrive.

  ## Why this process does so little

  An ETS table dies with its owner, so whoever owns it is a single point of data
  loss. This process therefore holds no interesting logic beyond validate-write-
  broadcast: its crash surface stays small while the process that does the risky
  thinking — the Queue — is free to die without taking the data with it.

  Metrics deliberately do **not** live here. They are handled with `:counters`
  (see `JobRunner.Jobs.Metrics`), because atomic increments from many worker
  processes are exactly the case where routing writes through one owner would be
  the wrong shape.
  """

  use GenServer

  alias JobRunner.Jobs.{Job, Metrics}
  alias Phoenix.PubSub

  require Logger

  @jobs_table :job_runner_jobs
  @dlq_table :job_runner_dlq
  @meta_table :job_runner_meta
  @pubsub JobRunner.PubSub
  @topic "jobs"

  # Which status transitions are legal. Anything absent is rejected, which turns
  # a whole class of ordering bug into a visible {:error, :invalid_transition}
  # rather than silent state corruption.
  @transitions %{
    pending: [:running],
    running: [:completed, :failed, :pending],
    # Terminal. Only an explicit requeue leaves these, and it goes through
    # requeue/1 rather than a bare transition.
    completed: [],
    failed: []
  }

  # --- Client: writes (serialised through the owner) --------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Admit a new job.

  Enforces `max_pending_jobs` here rather than in the Queue because this is the
  single write path: any other placement is a check that a concurrent caller can
  race past.
  """
  @spec insert(Job.t()) :: {:ok, Job.t()} | {:error, :queue_full | :already_exists}
  def insert(%Job{} = job), do: GenServer.call(__MODULE__, {:insert, job})

  @doc """
  Begin an attempt: mint the next `attempt_id`, spend one unit of budget, and
  move the job to `:running`.

  The token is minted **inside** the write path rather than passed in by the
  caller. If the Queue minted it, two dispatches racing on the same job could
  mint the same value; here that is impossible by construction.
  """
  @spec start_attempt(String.t()) ::
          {:ok, Job.t()} | {:error, :not_found | :invalid_transition | :exhausted}
  def start_attempt(job_id), do: GenServer.call(__MODULE__, {:start_attempt, job_id})

  @doc "Record success. Rejected unless `attempt_id` is the job's current attempt."
  @spec complete(String.t(), pos_integer(), term()) ::
          {:ok, Job.t()} | {:error, :not_found | :stale_attempt | :invalid_transition}
  def complete(job_id, attempt_id, result),
    do: GenServer.call(__MODULE__, {:complete, job_id, attempt_id, result})

  @doc "Record terminal failure and dead-letter the job."
  @spec fail(String.t(), pos_integer(), term()) ::
          {:ok, Job.t()} | {:error, :not_found | :stale_attempt | :invalid_transition}
  def fail(job_id, attempt_id, error),
    do: GenServer.call(__MODULE__, {:fail, job_id, attempt_id, error})

  @doc "Record a failed attempt that will be retried, and park the job until `next_run_at`."
  @spec schedule_retry(String.t(), pos_integer(), DateTime.t(), non_neg_integer(), term()) ::
          {:ok, Job.t()} | {:error, :not_found | :stale_attempt | :invalid_transition}
  def schedule_retry(job_id, attempt_id, next_run_at, backoff_ms, error),
    do:
      GenServer.call(
        __MODULE__,
        {:schedule_retry, job_id, attempt_id, next_run_at, backoff_ms, error}
      )

  @doc """
  Reconcile an attempt killed by a restart rather than by a failure.

  Returns the job to `:pending` and records the interruption in history, but
  does **not** spend budget: the attempt failed for our reasons, not the
  endpoint's.
  """
  @spec mark_interrupted(String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  def mark_interrupted(job_id), do: GenServer.call(__MODULE__, {:mark_interrupted, job_id})

  @doc "Replay a dead-lettered job with a fresh budget."
  @spec requeue(String.t()) :: {:ok, Job.t()} | {:error, :not_found | :not_dead_lettered}
  def requeue(job_id), do: GenServer.call(__MODULE__, {:requeue, job_id})

  # --- Client: reads (direct ETS, no message) ---------------------------------

  @doc "O(1) direct read. Never touches this process's mailbox."
  @spec fetch(String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  def fetch(job_id) do
    case :ets.lookup(@jobs_table, job_id) do
      [{^job_id, job}] -> {:ok, job}
      [] -> {:error, :not_found}
    end
  end

  @doc "All jobs, newest first."
  @spec all() :: [Job.t()]
  def all do
    @jobs_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, job} -> job end)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @doc "Every job in a non-terminal state — the input to recovery reconciliation."
  @spec non_terminal() :: [Job.t()]
  def non_terminal do
    @jobs_table
    |> :ets.select([{{:_, :"$1"}, [], [:"$1"]}])
    |> Enum.reject(&Job.terminal?/1)
    |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})
  end

  @spec dead_letters() :: [Job.t()]
  def dead_letters do
    @dlq_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, job} -> job end)
    |> Enum.sort_by(& &1.dead_lettered_at, {:desc, DateTime})
  end

  @spec count_by_status() :: %{Job.status() => non_neg_integer()}
  def count_by_status do
    base = %{pending: 0, running: 0, completed: 0, failed: 0}

    @jobs_table
    |> :ets.select([{{:_, :"$1"}, [], [:"$1"]}])
    |> Enum.reduce(base, fn job, acc -> Map.update(acc, job.status, 1, &(&1 + 1)) end)
  end

  @doc """
  Splits `:pending` into the two states it conflates:

    * **runnable** — in a priority FIFO, waiting for a free concurrency slot;
    * **scheduled** — waiting out a backoff on a timer, deliberately not in any
      FIFO, since a job waiting to retry must not hold a slot.

  Without the split, "Pending: 50, queue depth: 0" is a correct reading of a
  retry storm that looks exactly like a bug.
  """
  @spec pending_breakdown() :: %{runnable: non_neg_integer(), scheduled: non_neg_integer()}
  def pending_breakdown do
    now = DateTime.utc_now()

    @jobs_table
    |> :ets.select([{{:_, :"$1"}, [], [:"$1"]}])
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.reduce(%{runnable: 0, scheduled: 0}, fn job, acc ->
      if Job.delay_until_runnable(job, now) > 0 do
        Map.update!(acc, :scheduled, &(&1 + 1))
      else
        Map.update!(acc, :runnable, &(&1 + 1))
      end
    end)
  end

  @spec pending_count() :: non_neg_integer()
  def pending_count do
    :ets.select_count(@jobs_table, [
      {{:_, :"$1"},
       [
         {:orelse, {:==, {:map_get, :status, :"$1"}, :pending},
          {:==, {:map_get, :status, :"$1"}, :running}}
       ], [true]}
    ])
  end

  @doc """
  Current circuit breaker state. A direct ETS read — the dashboard polls this,
  and it must never queue behind dispatch.
  """
  @spec breaker() :: JobRunner.Jobs.Breaker.t()
  def breaker do
    case :ets.lookup(@meta_table, :breaker) do
      [{:breaker, breaker}] -> breaker
      [] -> JobRunner.Jobs.Breaker.new()
    end
  end

  @doc "Persist breaker state. Broadcasts so the dashboard reflects it live."
  @spec put_breaker(JobRunner.Jobs.Breaker.t()) :: :ok
  def put_breaker(breaker), do: GenServer.call(__MODULE__, {:put_breaker, breaker})

  @doc "Topic for `Phoenix.PubSub.subscribe/2`. Broadcasts `{:job_updated, job}`."
  @spec topic() :: String.t()
  def topic, do: @topic

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSub.subscribe(@pubsub, @topic)

  # --- Server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    # :protected — owner writes, world reads.
    # read_concurrency because reads vastly outnumber writes here.
    :ets.new(@jobs_table, [:set, :protected, :named_table, read_concurrency: true])
    :ets.new(@dlq_table, [:set, :protected, :named_table, read_concurrency: true])
    # Subsystem-wide state that is not a job: currently just the circuit breaker.
    # Held here rather than in the Queue's state so it survives a Queue restart —
    # an outage must not be forgotten because the scheduler blinked.
    :ets.new(@meta_table, [:set, :protected, :named_table, read_concurrency: true])
    :ets.insert(@meta_table, {:breaker, JobRunner.Jobs.Breaker.new()})
    # Counters are not ETS and not owned by anyone — see JobRunner.Jobs.Metrics.
    # Created here only because this is the first process in the subtree to start.
    JobRunner.Jobs.Metrics.setup()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:insert, job}, _from, state) do
    cond do
      :ets.member(@jobs_table, job.id) ->
        {:reply, {:error, :already_exists}, state}

      pending_count() >= max_pending_jobs() ->
        # Admission backpressure: bounding concurrent calls protects the
        # endpoint, but only bounding admission protects the VM.
        {:reply, {:error, :queue_full}, state}

      true ->
        Metrics.increment(:enqueued)
        {:reply, {:ok, put(job)}, state}
    end
  end

  def handle_call({:put_breaker, breaker}, _from, state) do
    previous = breaker()
    :ets.insert(@meta_table, {:breaker, breaker})

    # Only announce genuine transitions, not every counter tick.
    if previous.state != breaker.state do
      if breaker.state == :open, do: Metrics.increment(:breaker_trips)
      Logger.info("circuit breaker #{previous.state} -> #{breaker.state}")
      PubSub.broadcast(@pubsub, @topic, {:breaker_changed, breaker})
    end

    {:reply, :ok, state}
  end

  def handle_call({:start_attempt, job_id}, _from, state) do
    with {:ok, job} <- fetch(job_id),
         :ok <- check_transition(job, :running) do
      if Job.exhausted?(job) do
        {:reply, {:error, :exhausted}, state}
      else
        now = DateTime.utc_now()

        attempt = %{
          attempt_id: job.attempt_id + 1,
          attempt_no: job.attempts + 1,
          started_at: now,
          finished_at: nil,
          outcome: nil,
          error: nil,
          backoff_ms: nil
        }

        updated = %{
          job
          | status: :running,
            attempts: job.attempts + 1,
            attempt_id: job.attempt_id + 1,
            started_at: job.started_at || now,
            next_run_at: nil,
            history: [attempt | job.history]
        }

        Metrics.increment(:started)
        {:reply, {:ok, put(updated)}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:complete, job_id, attempt_id, result}, _from, state) do
    write(job_id, attempt_id, :completed, state, fn job, now ->
      Metrics.increment(:succeeded)

      %{
        job
        | status: :completed,
          result: result,
          error: nil,
          finished_at: now,
          next_run_at: nil,
          history: close_attempt(job.history, :ok, nil, nil, now)
      }
    end)
  end

  def handle_call({:fail, job_id, attempt_id, error}, _from, state) do
    write(job_id, attempt_id, :failed, state, fn job, now ->
      Metrics.increment(:failed)
      Metrics.increment(:dead_lettered)

      %{
        job
        | status: :failed,
          error: error,
          finished_at: now,
          next_run_at: nil,
          dead_lettered_at: now,
          history: close_attempt(job.history, :error, error, nil, now)
      }
    end)
  end

  def handle_call(
        {:schedule_retry, job_id, attempt_id, next_run_at, backoff_ms, error},
        _from,
        state
      ) do
    write(job_id, attempt_id, :pending, state, fn job, now ->
      Metrics.increment(:retried)

      %{
        job
        | status: :pending,
          error: error,
          next_run_at: next_run_at,
          history: close_attempt(job.history, :error, error, backoff_ms, now)
      }
    end)
  end

  def handle_call({:mark_interrupted, job_id}, _from, state) do
    case fetch(job_id) do
      {:ok, %Job{status: :running} = job} ->
        now = DateTime.utc_now()

        updated = %{
          job
          | status: :pending,
            next_run_at: nil,
            # Budget is refunded: the attempt died for our reasons.
            attempts: max(job.attempts - 1, 0),
            history: close_attempt(job.history, :interrupted, nil, nil, now)
        }

        {:reply, {:ok, put(updated)}, state}

      {:ok, job} ->
        # Idempotent: reconciliation may run twice, and a job already reconciled
        # is not an error.
        {:reply, {:ok, job}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:requeue, job_id}, _from, state) do
    case fetch(job_id) do
      {:ok, %Job{status: :failed} = job} ->
        :ets.delete(@dlq_table, job_id)
        Metrics.increment(:requeued)

        updated = %{
          job
          | status: :pending,
            attempts: 0,
            error: nil,
            finished_at: nil,
            next_run_at: nil,
            dead_lettered_at: nil
        }

        {:reply, {:ok, put(updated)}, state}

      {:ok, _job} ->
        {:reply, {:error, :not_dead_lettered}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # --- Internals -------------------------------------------------------------

  # Every status-changing write funnels through here, so the staleness check and
  # the transition check exist in exactly one place.
  defp write(job_id, attempt_id, target, state, fun) do
    with {:ok, job} <- fetch(job_id),
         :ok <- check_attempt(job, attempt_id),
         :ok <- check_transition(job, target) do
      updated = fun.(job, DateTime.utc_now())
      updated = if target == :failed, do: dead_letter(updated), else: updated
      {:reply, {:ok, put(updated)}, state}
    else
      {:error, reason} ->
        # Dropped stale outcomes are expected, not alarming.
        Logger.debug("store write rejected job=#{job_id} attempt=#{attempt_id} reason=#{reason}")
        {:reply, {:error, reason}, state}
    end
  end

  # Only the current attempt may change the job.
  defp check_attempt(%Job{attempt_id: current}, current), do: :ok
  defp check_attempt(%Job{}, _stale), do: {:error, :stale_attempt}

  defp check_transition(%Job{status: from}, to) do
    if to in Map.fetch!(@transitions, from), do: :ok, else: {:error, :invalid_transition}
  end

  defp close_attempt([current | rest], outcome, error, backoff_ms, now) do
    [%{current | outcome: outcome, error: error, backoff_ms: backoff_ms, finished_at: now} | rest]
  end

  defp close_attempt([], _outcome, _error, _backoff_ms, _now), do: []

  defp dead_letter(job) do
    :ets.insert(@dlq_table, {job.id, job})
    job
  end

  defp put(job) do
    :ets.insert(@jobs_table, {job.id, job})
    PubSub.broadcast(@pubsub, @topic, {:job_updated, job})
    job
  end

  defp max_pending_jobs do
    :job_runner |> Application.get_env(:jobs, []) |> Keyword.get(:max_pending_jobs, 10_000)
  end
end
