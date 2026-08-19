defmodule JobRunner.Jobs.Metrics do
  @moduledoc """
  Cumulative counters for the job system.

  ## Why `:counters` and not ETS

  Everything else in this subsystem lives in the Store's `:protected` ETS tables,
  written only by the owner. Counters are the deliberate exception,
  and the exception is instructive.

  Job records have invariants — a status transition must be legal, an attempt
  token must be current — so they need a single validated write path. A counter
  has no invariants: it only ever goes up, and every increment is independent of
  every other. Routing those through one process would add a message hop and a
  serialisation point to buy nothing.

  `:counters` gives atomic increments from any process with no owner and no
  lock. The reference lives in `:persistent_term`, which is optimised for
  exactly this: written once, read from everywhere, no copying on read.
  ## Cumulative, not current

  These count *events over time* and never decrease. Current state — how many
  jobs are pending right now — is a question for the Store, which knows. Mixing
  the two in one place is how you end up with a gauge that drifts out of sync
  with reality after a restart.
  """

  @counters [
    :enqueued,
    :started,
    :succeeded,
    :failed,
    :retried,
    :dead_lettered,
    :requeued,
    :crashed,
    :timed_out,
    :breaker_trips,
    :tool_calls
  ]

  @key {__MODULE__, :ref}

  @doc """
  Create the counter array if it does not already exist.

  Idempotent on purpose. This is called from `Store.init/1`, which runs again on
  every Store restart — creating a fresh array there would silently reset the
  lifetime counters, so "jobs processed since boot" would quietly become "since
  the last crash". Counters outlive the processes that write to them.
  """
  @spec setup() :: :ok
  def setup do
    case :persistent_term.get(@key, nil) do
      nil ->
        :persistent_term.put(@key, :counters.new(length(@counters), [:write_concurrency]))
        :ok

      _existing ->
        :ok
    end
  end

  @doc "Increment a counter. Safe from any process, no message, no lock."
  @spec increment(atom(), pos_integer()) :: :ok
  def increment(name, by \\ 1) do
    case index(name) do
      nil -> :ok
      index -> :counters.add(ref(), index, by)
    end
  end

  @doc "All counters as a map."
  @spec all() :: %{atom() => non_neg_integer()}
  def all do
    reference = ref()

    @counters
    |> Enum.with_index(1)
    |> Map.new(fn {name, index} -> {name, :counters.get(reference, index)} end)
  end

  @doc "One counter's value."
  @spec get(atom()) :: non_neg_integer()
  def get(name) do
    case index(name) do
      nil -> 0
      index -> :counters.get(ref(), index)
    end
  end

  @doc """
  Derived rates, for the dashboard.
  """
  @spec summary() :: map()
  def summary do
    counters = all()
    finished = counters.succeeded + counters.failed

    counters
    |> Map.put(:processed, finished)
    |> Map.put(:success_rate, percentage(counters.succeeded, finished))
    |> Map.put(:retry_rate, percentage(counters.retried, counters.started))
  end

  @doc "Reset every counter. Test support only."
  @spec reset() :: :ok
  def reset do
    reference = ref()

    for index <- 1..length(@counters) do
      :counters.put(reference, index, 0)
    end

    :ok
  end

  defp percentage(_part, 0), do: nil
  defp percentage(part, whole), do: Float.round(part * 100 / whole, 1)

  defp index(name) do
    case Enum.find_index(@counters, &(&1 == name)) do
      nil -> nil
      index -> index + 1
    end
  end

  # Lazily created so metrics work even if something increments before setup —
  # a missing counter must never be the reason a job fails.
  defp ref do
    case :persistent_term.get(@key, nil) do
      nil ->
        setup()
        :persistent_term.get(@key)

      existing ->
        existing
    end
  end
end
