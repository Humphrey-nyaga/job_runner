defmodule JobRunner.Jobs.Queue do
  @moduledoc """
  The scheduler: decides *what* runs, *when*, and *how many at once*.

  This is the only process that makes decisions. The Store holds truth, Tasks do
  work, and the pure modules (`Backoff`, `Failure`) hold the judgement. The Queue
  is where they meet.

  ## What it owns

    * three FIFOs, one per priority, plus the anti-starvation rule
    * the concurrency gate — never more than `max_concurrency` live tasks
    * the retry timers, so backoff never occupies a worker slot
    * a per-attempt deadline, because an HTTP receive timeout is not a job
      timeout
    * reconciliation on startup, so a crash cannot strand a job in `:running`


  ## What it deliberately does not own

  Job records. Those live in the Store, which outlives this process by design.
  Everything in this GenServer's state is *ephemeral bookkeeping* — which pids
  are live right now — and is meaningless after a restart anyway. That split is
  why a Queue crash loses nothing that matters.

  ## The message protocol

  A dispatched attempt can produce five different messages, and they race:

      {ref, result}                      the task returned
      {:DOWN, ref, :process, pid, :normal}... and then exited
      {:DOWN, ref, :process, pid, reason}    the task crashed
      {:job_timeout, job_id, attempt_id}     our deadline fired
      (nothing)                              the task is wedged

  Two bugs live here. A success followed by a `:DOWN` can be read as a second,
  contradictory outcome — prevented with `Process.demonitor(ref, [:flush])`,
  which removes the monitor *and* purges any already-queued `:DOWN`. And a
  deadline armed for attempt 3 can fire during attempt 4 — prevented by keying
  every timer message with `attempt_id` and dropping mismatches.

  The Store re-checks the same token on write, so correctness does not depend on
  this process getting its bookkeeping perfect. Two independent guards.
  """

  use GenServer

  alias JobRunner.Jobs.{Backoff, Breaker, Failure, Job, Metrics, Store, Worker}

  require Logger

  @priorities [:high, :normal, :low]

  # Every Nth dispatch is forced to serve the lowest non-empty queue, so a
  # sustained stream of high-priority work cannot starve the tail.
  @starvation_interval 4

  defstruct queues: %{},
            in_flight: %{},
            dispatched: 0,
            max_concurrency: 4,
            task_supervisor: JobRunner.Jobs.TaskSupervisor,
            llm_opts: [],
            breaker_timer_armed: false

  # --- Client ----------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Add an already-stored job to the run queue."
  @spec enqueue(Job.t()) :: :ok
  def enqueue(%Job{} = job), do: GenServer.cast(__MODULE__, {:enqueue, job.id, job.priority})

  @doc "Number of tasks currently running. Used by tests and the dashboard."
  @spec in_flight_count() :: non_neg_integer()
  def in_flight_count, do: GenServer.call(__MODULE__, :in_flight_count)

  @doc """
  The concurrency ceiling this Queue is actually running with.

  Read from the process rather than from config: the Queue can be started with an
  explicit `:max_concurrency`, so config is only the default and reporting it
  would make the dashboard lie whenever the two differ.
  """
  @spec max_concurrency() :: pos_integer()
  def max_concurrency, do: GenServer.call(__MODULE__, :max_concurrency)

  @doc "Depth of each priority queue."
  @spec queue_depths() :: %{Job.priority() => non_neg_integer()}
  def queue_depths, do: GenServer.call(__MODULE__, :queue_depths)

  @doc false
  # Test seam: block until every message already in the mailbox is processed.
  def sync, do: GenServer.call(__MODULE__, :sync)

  # --- Server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      queues: Map.new(@priorities, &{&1, :queue.new()}),
      max_concurrency: Keyword.get(opts, :max_concurrency, config(:max_concurrency, 4)),
      task_supervisor: Keyword.get(opts, :task_supervisor, JobRunner.Jobs.TaskSupervisor),
      llm_opts: Keyword.get(opts, :llm_opts, [])
    }

    # Reconciliation is deferred to handle_continue so init/1 stays fast and the
    # supervisor is not blocked while we sweep the Store.
    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    {:noreply, state |> reconcile() |> dispatch()}
  end

  @impl true
  def handle_cast({:enqueue, job_id, priority}, state) do
    {:noreply, state |> push(job_id, priority) |> dispatch()}
  end

  @impl true
  def handle_call(:in_flight_count, _from, state), do: {:reply, map_size(state.in_flight), state}

  def handle_call(:queue_depths, _from, state) do
    {:reply, Map.new(state.queues, fn {p, q} -> {p, :queue.len(q)} end), state}
  end

  def handle_call(:max_concurrency, _from, state),
    do: {:reply, state.max_concurrency, state}

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  # A task returned a value. The result is handled and the monitor torn down
  # here, before the Store is touched.
  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case pop_in_flight(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {attempt, state} ->
        # Removes the monitor AND flushes any :DOWN already in our mailbox, so
        # the normal exit that follows cannot be read as a second outcome.
        Process.demonitor(ref, [:flush])
        cancel_timer(attempt.timer_ref)

        {:noreply, state |> settle(attempt, result) |> dispatch()}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case pop_in_flight(state, ref) do
      {nil, state} ->
        # Already settled — this is the flushed-away normal exit, or a task we
        # killed ourselves on deadline.
        {:noreply, state}

      {attempt, state} ->
        cancel_timer(attempt.timer_ref)

        Metrics.increment(:crashed)

        Logger.warning(
          "job #{attempt.job_id} attempt #{attempt.attempt_id} crashed: #{inspect(reason)}"
        )

        {:noreply, state |> settle(attempt, {:error, {:crash, reason}}) |> dispatch()}
    end
  end

  # Our own deadline fired. The attempt_id is what makes a stale
  # timer from a previous attempt harmless.
  def handle_info({:job_timeout, job_id, attempt_id}, state) do
    case find_in_flight(state, job_id, attempt_id) do
      nil ->
        {:noreply, state}

      {ref, attempt} ->
        {_, state} = pop_in_flight(state, ref)
        Metrics.increment(:timed_out)
        Process.demonitor(ref, [:flush])
        Task.Supervisor.terminate_child(state.task_supervisor, attempt.pid)

        {:noreply, state |> settle(attempt, {:error, :job_timeout}) |> dispatch()}
    end
  end

  # A backoff elapsed; the job is runnable again.
  def handle_info({:retry, job_id}, state) do
    case Store.fetch(job_id) do
      {:ok, %Job{status: :pending} = job} ->
        {:noreply, state |> push(job_id, job.priority) |> dispatch()}

      # Completed, failed, or requeued elsewhere in the meantime.
      _ ->
        {:noreply, state}
    end
  end

  # The breaker's cooldown may have elapsed. Nothing else would wake us during
  # an outage, so this timer is what makes recovery automatic.
  def handle_info(:breaker_check, state) do
    {:noreply, dispatch(%{state | breaker_timer_armed: false})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- Recovery

  # Every non-terminal record is reconciled, not just the pending ones. A sweep
  # that only re-enqueued :pending would leave jobs killed mid-flight stuck in
  # :running forever — a permanent lie in the API the brief asks to be queryable.
  defp reconcile(state) do
    Store.non_terminal()
    |> Enum.reduce(state, fn job, acc ->
      case job.status do
        :running ->
          # The task died with the previous Queue. Refund the attempt (it failed
          # for our reasons) and make the job runnable again.
          {:ok, job} = Store.mark_interrupted(job.id)
          Logger.info("reconciled interrupted job #{job.id}")
          push(acc, job.id, job.priority)

        :pending ->
          case Job.delay_until_runnable(job, DateTime.utc_now()) do
            0 -> push(acc, job.id, job.priority)
            delay -> schedule_retry_timer(acc, job.id, delay)
          end
      end
    end)
  end

  # --- Dispatch

  # Fill every free slot. Recurses until a gate closes or the queues empty, so a
  # single call after any state change is always sufficient.
  #
  # Two gates, checked in order: the concurrency ceiling, then the circuit
  # breaker. When the breaker denies — we return *without
  # popping anything*. Jobs stay queued with their attempt budgets untouched,
  # which is the entire point: an outage should cost time, not jobs.
  defp dispatch(state) do
    cond do
      map_size(state.in_flight) >= state.max_concurrency ->
        state

      true ->
        case gate(state) do
          {:deny, state} ->
            state

          {mode, state} ->
            case pop_next(state) do
              {nil, state} ->
                state

              {job_id, state} ->
                case start_attempt(state, job_id) do
                  {state, :dispatched} when mode == :probe ->
                    # Only now is a probe genuinely in flight. Marking it when
                    # permission was merely *granted* deadlocks the breaker: it
                    # would wait forever for a verdict on a probe never sent.
                    Store.put_breaker(Breaker.probe_dispatched(Store.breaker()))
                    # A probe is a single job, not a floodgate — an endpoint that
                    # has only just come back must not meet the whole backlog.
                    state

                  {state, :dispatched} ->
                    dispatch(state)

                  {state, :skipped} ->
                    # Exhausted or already settled, so nothing was sent. A probe
                    # grant must not be consumed by a no-op; try the next job.
                    dispatch(state)
                end
            end
        end
    end
  end

  # Consulting the breaker can itself cause a transition (an open breaker whose
  # cooldown has elapsed becomes half-open on read), so the result is persisted.
  defp gate(state) do
    breaker = Store.breaker()

    case Breaker.allow?(breaker, DateTime.utc_now()) do
      {decision, ^breaker} ->
        {decision, state}

      {decision, updated} ->
        Store.put_breaker(updated)
        {decision, state}
    end
    |> maybe_schedule_breaker_check()
  end

  # While the breaker is open nothing arrives to wake us, so we must arm our own
  # timer — otherwise the queue would sit idle until the next submission.
  defp maybe_schedule_breaker_check({:deny, state}) do
    unless state.breaker_timer_armed do
      delay = Breaker.time_until_probe(Store.breaker(), DateTime.utc_now())
      Process.send_after(self(), :breaker_check, max(delay, 50))
    end

    {:deny, %{state | breaker_timer_armed: true}}
  end

  defp maybe_schedule_breaker_check(result), do: result

  defp start_attempt(state, job_id) do
    case Store.start_attempt(job_id) do
      {:ok, job} ->
        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            Worker.run(job, state.llm_opts)
          end)

        timer_ref =
          Process.send_after(self(), {:job_timeout, job.id, job.attempt_id}, job_timeout())

        attempt = %{
          job_id: job.id,
          attempt_id: job.attempt_id,
          pid: task.pid,
          timer_ref: timer_ref
        }

        {%{
           state
           | in_flight: Map.put(state.in_flight, task.ref, attempt),
             dispatched: state.dispatched + 1
         }, :dispatched}

      {:error, :exhausted} ->
        # Defence in depth. A job that is :pending but out of budget can never be
        # dispatched, and dropping it here would leave it :pending forever with
        # nothing to fail it — invisible, permanent, and indistinguishable from a
        # stuck queue. Admission validation should make this unreachable; if it
        # ever happens anyway, fail the job loudly instead of losing it.
        Logger.warning("job #{job_id} was pending but exhausted; failing it")

        case Store.fetch(job_id) do
          {:ok, job} -> Store.fail(job_id, job.attempt_id, {:exhausted, :no_attempts_remaining})
          _ -> :ok
        end

        {state, :skipped}

      {:error, reason} ->
        # Already running, or vanished. Not fatal — drop it and let the next
        # dispatch proceed. The caller must know nothing was sent, so that a
        # circuit-breaker probe grant is not silently consumed.
        Logger.debug("skipping dispatch of #{job_id}: #{inspect(reason)}")
        {state, :skipped}
    end
  end

  # --- Settlement

  defp settle(state, attempt, {:ok, result}) do
    Store.complete(attempt.job_id, attempt.attempt_id, result)
    # Any success is evidence of recovery: it closes a half-open breaker and
    # resets the consecutive-failure count.
    record_breaker(state, :success)
  end

  defp settle(state, attempt, {:error, reason}) do
    class = Failure.classify(reason)
    state = record_breaker(state, {:failure, class})

    case Store.fetch(attempt.job_id) do
      {:ok, job} -> apply_policy(state, job, attempt, reason, class)
      {:error, :not_found} -> state
    end
  end

  # The breaker is only fed *outcomes*, never intentions — it is a record of what
  # the endpoint actually did.
  defp record_breaker(state, outcome) do
    before = Store.breaker()

    updated =
      case outcome do
        :success -> Breaker.record_success(before)
        {:failure, class} -> Breaker.record_failure(before, class, DateTime.utc_now())
      end

    if updated != before, do: Store.put_breaker(updated)

    # Once the breaker closes, the timer that was waking us during the outage is
    # no longer needed; clearing the flag lets a future outage arm a fresh one.
    if Breaker.open?(updated), do: state, else: %{state | breaker_timer_armed: false}
  end

  # The retry decision, in one place, reading like the policy it is.
  defp apply_policy(state, job, attempt, reason, class) do
    cond do
      # Repeating this sends identical bytes and fails identically.
      class == :permanent ->
        fail(state, attempt, reason)

      # Our own bug: usually deterministic, so a reduced budget (Failure
      # .crash_retry_budget/0) rather than the full one.
      crash?(reason) and job.attempts >= Failure.crash_retry_budget() ->
        fail(state, attempt, reason)

      job.attempts >= job.max_attempts ->
        fail(state, attempt, reason)

      true ->
        retry(state, job, attempt, reason)
    end
  end

  defp retry(state, job, attempt, reason) do
    delay = Backoff.delay(job.attempts)
    next_run_at = DateTime.add(DateTime.utc_now(), delay, :millisecond)

    case Store.schedule_retry(attempt.job_id, attempt.attempt_id, next_run_at, delay, reason) do
      {:ok, _job} ->
        # The slot is ALREADY free — we are not sleeping here, we are arming a
        # timer and returning to serve other jobs.
        schedule_retry_timer(state, attempt.job_id, delay)

      {:error, _reason} ->
        state
    end
  end

  defp fail(state, attempt, reason) do
    Store.fail(attempt.job_id, attempt.attempt_id, reason)
    state
  end

  defp crash?({:crash, _}), do: true
  defp crash?(_), do: false

  defp schedule_retry_timer(state, job_id, delay) do
    Process.send_after(self(), {:retry, job_id}, delay)
    state
  end

  # --- Priority queues

  defp push(state, job_id, priority) do
    priority = if priority in @priorities, do: priority, else: :normal
    queues = Map.update!(state.queues, priority, &:queue.in(job_id, &1))
    %{state | queues: queues}
  end

  # Strict priority would starve the tail under sustained high-priority load, so
  # every Nth dispatch deliberately serves the lowest non-empty queue instead.
  defp pop_next(state) do
    order =
      if rem(state.dispatched + 1, @starvation_interval) == 0 do
        Enum.reverse(@priorities)
      else
        @priorities
      end

    pop_from(state, order)
  end

  defp pop_from(state, []), do: {nil, state}

  defp pop_from(state, [priority | rest]) do
    case :queue.out(Map.fetch!(state.queues, priority)) do
      {{:value, job_id}, remaining} ->
        {job_id, %{state | queues: Map.put(state.queues, priority, remaining)}}

      {:empty, _} ->
        pop_from(state, rest)
    end
  end

  # --- In-flight bookkeeping

  defp pop_in_flight(state, ref) do
    case Map.pop(state.in_flight, ref) do
      {nil, _} -> {nil, state}
      {attempt, in_flight} -> {attempt, %{state | in_flight: in_flight}}
    end
  end

  defp find_in_flight(state, job_id, attempt_id) do
    Enum.find(state.in_flight, fn {_ref, attempt} ->
      attempt.job_id == job_id and attempt.attempt_id == attempt_id
    end)
  end

  # Best-effort only: the message may already be in our mailbox. The attempt_id
  # check is what makes correctness independent of this succeeding.
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp job_timeout, do: config(:job_timeout_ms, 60_000)

  defp config(key, default) do
    :job_runner |> Application.get_env(:jobs, []) |> Keyword.get(key, default)
  end
end
