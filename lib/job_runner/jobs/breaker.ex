defmodule JobRunner.Jobs.Breaker do
  @moduledoc """
  Three-state circuit breaker guarding dispatch: `:closed`, `:open`, `:half_open`.

  Pure — every function takes the current state and `now` and returns a new
  state, so cooldown schedules are verifiable without waiting.

  Only `:systemic` failures move the counter, and any success resets it to zero.
  "Consecutive" means consecutive in completion order, which is the only order
  this process observes.

  In `:half_open` exactly one probe may be in flight. It is marked by
  `probe_dispatched/1` once a job has actually been sent; flagging it when
  permission was granted would deadlock the breaker if the dispatch never
  happened.
  """

  alias JobRunner.Jobs.Failure

  @type state :: :closed | :open | :half_open

  @type t :: %__MODULE__{
          state: state(),
          failures: non_neg_integer(),
          opened_at: DateTime.t() | nil,
          cooldown_ms: pos_integer() | nil,
          probe_in_flight: boolean(),
          trips: non_neg_integer()
        }

  defstruct state: :closed,
            failures: 0,
            opened_at: nil,
            cooldown_ms: nil,
            probe_in_flight: false,
            trips: 0

  @doc """
  A fresh, closed breaker.

  `cooldown_ms` is `nil`, meaning "the configured base, resolved when used".
  This struct is built once in `Store.init/1`, so baking the value in would
  freeze it and silently ignore any later config change. Only *doubling* writes
  an explicit value, because that is state rather than configuration.
  """
  @spec new(keyword()) :: t()
  def new(_opts \\ []), do: %__MODULE__{}

  @doc "The cooldown in force: an explicitly doubled value, else the configured base."
  @spec cooldown(t(), keyword()) :: pos_integer()
  def cooldown(breaker, opts \\ [])
  def cooldown(%__MODULE__{cooldown_ms: nil}, opts), do: base_cooldown(opts)
  def cooldown(%__MODULE__{cooldown_ms: ms}, _opts), do: ms

  @doc """
  May a job be dispatched right now? Returns `:allow`, `:probe` (exactly one
  job, as a recovery probe) or `:deny`.

  Returns the possibly-updated breaker too, because asking can itself cause a
  transition: an `:open` breaker whose cooldown has elapsed becomes `:half_open`
  when consulted. Deriving that from the clock rather than a timer process means
  the two cannot drift apart.
  """
  @spec allow?(t(), DateTime.t(), keyword()) :: {:allow | :probe | :deny, t()}
  def allow?(breaker, now \\ DateTime.utc_now(), opts \\ [])

  def allow?(%__MODULE__{state: :closed} = breaker, _now, _opts), do: {:allow, breaker}

  def allow?(%__MODULE__{state: :open} = breaker, now, opts) do
    if cooled_down?(breaker, now, opts) do
      {:probe, %{breaker | state: :half_open}}
    else
      {:deny, breaker}
    end
  end

  def allow?(%__MODULE__{state: :half_open, probe_in_flight: true} = breaker, _now, _opts) do
    # A probe is already out. Everything else waits for its verdict.
    {:deny, breaker}
  end

  def allow?(%__MODULE__{state: :half_open} = breaker, _now, _opts) do
    {:probe, breaker}
  end

  @doc """
  Mark that a granted probe was **actually dispatched**.

  Separate from `allow?/3` because granting and dispatching can come apart: the
  chosen job may be exhausted or already settled, in which case nothing is sent
  and no outcome will ever arrive. Flagging on intent would leave the breaker
  waiting forever in `:half_open` for a verdict on a probe that was never
  sent.
  """
  @spec probe_dispatched(t()) :: t()
  def probe_dispatched(%__MODULE__{state: :half_open} = breaker),
    do: %{breaker | probe_in_flight: true}

  def probe_dispatched(%__MODULE__{} = breaker), do: breaker

  @doc """
  Record a successful call.

  From `:half_open` this closes the breaker and resets the cooldown — recovery
  is automatic and needs no operator action.
  """
  @spec record_success(t(), keyword()) :: t()
  def record_success(%__MODULE__{} = breaker, _opts \\ []) do
    %{
      breaker
      | state: :closed,
        failures: 0,
        opened_at: nil,
        probe_in_flight: false,
        trips: 0,
        # Back to "use the configured base", not to a snapshot of it.
        cooldown_ms: nil
    }
  end

  @doc """
  Record a failed call, given its `JobRunner.Jobs.Failure` classification.

  Non-systemic failures are inconclusive: they clear any in-flight probe (so the
  next job may probe again) but neither trip nor reset the breaker.
  """
  @spec record_failure(t(), Failure.class(), DateTime.t(), keyword()) :: t()
  def record_failure(breaker, class, now \\ DateTime.utc_now(), opts \\ [])

  def record_failure(%__MODULE__{} = breaker, class, now, opts) do
    if Failure.systemic?(class) do
      systemic_failure(breaker, now, opts)
    else
      %{breaker | probe_in_flight: false}
    end
  end

  # A failed probe means the endpoint is still unwell. Back to open, and wait
  # longer this time — repeatedly probing a dead service at a fixed interval is
  # just a slower version of the hammering the breaker exists to stop.
  defp systemic_failure(%__MODULE__{state: :half_open} = breaker, now, opts) do
    %{
      breaker
      | state: :open,
        opened_at: now,
        probe_in_flight: false,
        trips: breaker.trips + 1,
        cooldown_ms: next_cooldown(breaker, opts)
    }
  end

  defp systemic_failure(%__MODULE__{} = breaker, now, opts) do
    failures = breaker.failures + 1

    if failures >= threshold(opts) do
      %{
        breaker
        | state: :open,
          failures: failures,
          opened_at: now,
          probe_in_flight: false,
          trips: breaker.trips + 1
      }
    else
      %{breaker | failures: failures}
    end
  end

  @doc "Milliseconds until an open breaker may next be probed; 0 if it already may."
  @spec time_until_probe(t(), DateTime.t(), keyword()) :: non_neg_integer()
  def time_until_probe(breaker, now, opts \\ [])

  def time_until_probe(%__MODULE__{state: :open, opened_at: opened_at} = breaker, now, opts)
      when not is_nil(opened_at) do
    elapsed = DateTime.diff(now, opened_at, :millisecond)
    max(cooldown(breaker, opts) - elapsed, 0)
  end

  def time_until_probe(%__MODULE__{}, _now, _opts), do: 0

  @doc "True when dispatch is currently suppressed."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{state: :open}), do: true
  def open?(%__MODULE__{}), do: false

  defp cooled_down?(breaker, now, opts), do: time_until_probe(breaker, now, opts) == 0

  # Doubling, capped. Without a cap a long outage would push the retry interval
  # out to hours and the system would take hours to notice recovery.
  defp next_cooldown(breaker, opts) do
    max_cooldown = Keyword.get(opts, :max_cooldown_ms, config(:breaker_max_cooldown_ms, 300_000))
    min(cooldown(breaker, opts) * 2, max_cooldown)
  end

  defp base_cooldown(opts),
    do: Keyword.get(opts, :cooldown_ms, config(:breaker_cooldown_ms, 30_000))

  defp threshold(opts), do: Keyword.get(opts, :threshold, config(:breaker_threshold, 5))

  defp config(key, default) do
    :job_runner |> Application.get_env(:jobs, []) |> Keyword.get(key, default)
  end
end
