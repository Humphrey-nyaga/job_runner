defmodule JobRunner.Jobs.Backoff do
  @moduledoc """
  Delay before the next attempt. Pure — no processes, no clock, so the whole
  schedule is verifiable without waiting.

  `base × 2^(attempt-1)`, capped, with a ±25% proportional jitter band.

  The jitter is not decoration. Exponential backoff alone leaves a batch that
  failed together retrying together, in synchronised waves against an endpoint
  that is already struggling. The curve controls how hard the system retries;
  the jitter controls whether it all happens at once.
  """

  @doc """
  Delay in milliseconds before `attempt` is retried, where `attempt` counts
  attempts already made — so the first retry is `attempt: 1` and equals `base`.

  Options default to `config :job_runner, :jobs`:

    * `:base_ms` — first delay, doubled each attempt
    * `:max_ms` — ceiling applied *before* jitter, so a jittered value may
      exceed it slightly; clamping afterwards would pile probability mass on
      the cap itself
    * `:jitter` — proportional band; `0.0` disables it, which is what makes
      timing assertions in tests deterministic
  """
  @spec delay(pos_integer(), keyword()) :: non_neg_integer()
  def delay(attempt, opts \\ []) when is_integer(attempt) and attempt >= 1 do
    base = Keyword.get(opts, :base_ms, config(:backoff_base_ms, 500))
    max = Keyword.get(opts, :max_ms, config(:backoff_max_ms, 30_000))
    jitter = Keyword.get(opts, :jitter, config(:backoff_jitter, 0.25))

    base
    |> nominal(attempt, max)
    |> apply_jitter(jitter)
  end

  @doc """
  The un-jittered schedule, for documentation and tests.

      iex> JobRunner.Jobs.Backoff.schedule(4)
      [500, 1000, 2000, 4000]
  """
  @spec schedule(pos_integer(), keyword()) :: [non_neg_integer()]
  def schedule(count, opts \\ []) do
    for attempt <- 1..count, do: delay(attempt, Keyword.put(opts, :jitter, 0.0))
  end

  # 2^(attempt-1) growth, capped. Guarding the exponent matters: without the cap
  # on `attempt`, a large attempt count would compute an enormous integer before
  # min/2 discarded it.
  defp nominal(base, attempt, max) do
    exponent = min(attempt - 1, 32)
    min(base * Bitwise.bsl(1, exponent), max)
  end

  defp apply_jitter(delay, jitter) when jitter <= 0.0, do: delay

  defp apply_jitter(delay, jitter) do
    spread = delay * jitter
    offset = :rand.uniform() * 2 * spread - spread

    (delay + offset) |> round() |> max(0)
  end

  defp config(key, default) do
    :job_runner |> Application.get_env(:jobs, []) |> Keyword.get(key, default)
  end
end
