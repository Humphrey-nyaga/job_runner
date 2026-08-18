defmodule JobRunner.Jobs.BreakerTest do
  @moduledoc """
  The breaker state machine in isolation.

  Because `Breaker` is pure and takes `now` as an argument, a 5-minute cooldown
  schedule is tested in microseconds. That is the whole reason the clock is a
  parameter rather than a call to `DateTime.utc_now/0` inside the module.
  """

  use ExUnit.Case, async: true

  alias JobRunner.Jobs.Breaker

  @opts [threshold: 5, cooldown_ms: 30_000, max_cooldown_ms: 300_000]
  @now ~U[2026-01-01 12:00:00Z]

  defp after_ms(ms), do: DateTime.add(@now, ms, :millisecond)

  defp fail(breaker, class, now \\ @now),
    do: Breaker.record_failure(breaker, class, now, @opts)

  defp fail_times(breaker, n, class \\ :systemic) do
    Enum.reduce(1..n, breaker, fn _, acc -> fail(acc, class) end)
  end

  defp new, do: Breaker.new(@opts)

  describe "tripping" do
    test "starts closed and allows dispatch" do
      assert {:allow, _} = Breaker.allow?(new(), @now)
    end

    test "stays closed below the threshold" do
      breaker = fail_times(new(), 4)

      assert breaker.state == :closed
      assert breaker.failures == 4
      assert {:allow, _} = Breaker.allow?(breaker, @now)
    end

    test "opens exactly at the threshold" do
      breaker = fail_times(new(), 5)

      assert breaker.state == :open
      assert breaker.trips == 1
      assert {:deny, _} = Breaker.allow?(breaker, @now)
    end

    test "a success resets the count" do
      breaker = new() |> fail_times(4) |> Breaker.record_success(@opts) |> fail_times(4)

      # Consecutive means consecutive. Eight failures, but never five in a row.
      assert breaker.state == :closed
    end
  end

  describe "what must NOT trip it" do
    test "permanent failures never count" do
      breaker = fail_times(new(), 20, :permanent)

      # One malformed prompt returning 400 must not take the system offline.
      assert breaker.state == :closed
      assert breaker.failures == 0
    end

    test "retryable-but-not-systemic failures never count" do
      # A model returning garbage means the endpoint is healthy and answering;
      # only the generation was unusable.
      breaker = fail_times(new(), 20, :retryable)

      assert breaker.state == :closed
      assert breaker.failures == 0
    end

    test "non-systemic failures are inconclusive, not a reset" do
      breaker = new() |> fail_times(3) |> fail_times(5, :retryable)

      # Neither tripped nor reset: the count stands where the systemic failures
      # left it.
      assert breaker.state == :closed
      assert breaker.failures == 3
    end
  end

  describe "half-open" do
    setup do
      {:ok, breaker: fail_times(new(), 5)}
    end

    test "denies dispatch during the cooldown", %{breaker: breaker} do
      assert {:deny, _} = Breaker.allow?(breaker, after_ms(29_999))
    end

    test "becomes half-open once the cooldown elapses", %{breaker: breaker} do
      assert {:probe, probing} = Breaker.allow?(breaker, after_ms(30_000))
      assert probing.state == :half_open
      # Granting permission is not the same as dispatching — see probe_dispatched/1.
      refute probing.probe_in_flight
    end

    test "a granted probe that is never dispatched does not deadlock the breaker" do
      # The Queue may grant a probe and then find the chosen job exhausted, so
      # nothing is sent and no outcome will ever arrive. Were the in-flight flag
      # set on the grant, the breaker would wait forever in half-open, denying
      # every job.
      breaker = fail_times(new(), 5)

      {:probe, granted} = Breaker.allow?(breaker, after_ms(30_000))

      # Nothing dispatched: the next job must still be allowed to probe.
      assert {:probe, _} = Breaker.allow?(granted, after_ms(30_001))
    end

    test "allows exactly ONE probe, not the whole backlog", %{breaker: breaker} do
      {:probe, probing} = Breaker.allow?(breaker, after_ms(30_000))
      probing = Breaker.probe_dispatched(probing)

      # An endpoint that has just come back must not be met with everything at
      # once — that is how a recovering service is knocked over again.
      assert {:deny, _} = Breaker.allow?(probing, after_ms(30_001))
      assert {:deny, _} = Breaker.allow?(probing, after_ms(31_000))
    end

    test "a successful probe closes the breaker and resets the cooldown",
         %{breaker: breaker} do
      {:probe, probing} = Breaker.allow?(breaker, after_ms(30_000))
      probing = Breaker.probe_dispatched(probing)
      closed = Breaker.record_success(probing, @opts)

      assert closed.state == :closed
      assert closed.failures == 0
      assert Breaker.cooldown(closed, @opts) == 30_000
      assert {:allow, _} = Breaker.allow?(closed, after_ms(30_001))
    end

    test "a failed probe reopens immediately, without needing 5 more failures",
         %{breaker: breaker} do
      {:probe, probing} = Breaker.allow?(breaker, after_ms(30_000))
      probing = Breaker.probe_dispatched(probing)
      reopened = fail(probing, :systemic, after_ms(30_100))

      assert reopened.state == :open
      assert Breaker.cooldown(reopened, @opts) == 60_000
    end

    test "a probe failing non-systemically clears the probe without reopening",
         %{breaker: breaker} do
      {:probe, probing} = Breaker.allow?(breaker, after_ms(30_000))
      probing = Breaker.probe_dispatched(probing)
      after_400 = fail(probing, :permanent, after_ms(30_100))

      # A 400 proves the endpoint is answering, so it is not evidence of illness
      # — but it is not evidence of health either. Another job may probe.
      assert after_400.state == :half_open
      refute after_400.probe_in_flight
      assert {:probe, _} = Breaker.allow?(after_400, after_ms(30_200))
    end
  end

  describe "cooldown backoff" do
    # Each probe must happen *after* the current cooldown has elapsed, so the
    # clock advances with the breaker. Probing at a fixed instant would simply
    # be denied — which is itself the behaviour under test elsewhere.
    defp probe_and_fail(n) do
      Enum.map_reduce(1..n, {fail_times(new(), 5), 0}, fn _, {breaker, elapsed} ->
        elapsed = elapsed + Breaker.cooldown(breaker, @opts)
        {:probe, probing} = Breaker.allow?(breaker, after_ms(elapsed))
        probing = Breaker.probe_dispatched(probing)
        failed = fail(probing, :systemic, after_ms(elapsed))
        {Breaker.cooldown(failed, @opts), {failed, elapsed}}
      end)
    end

    test "doubles on each consecutive failed probe, capped" do
      {cooldowns, _} = probe_and_fail(6)

      # Repeatedly probing a dead service at a fixed interval is just a slower
      # version of the hammering the breaker exists to prevent.
      assert cooldowns == [60_000, 120_000, 240_000, 300_000, 300_000, 300_000]
    end

    test "the cap keeps recovery detection bounded" do
      # Without a cap, a long outage would push the probe interval out to hours
      # and the system would take hours to notice the endpoint had come back.
      {cooldowns, _} = probe_and_fail(12)

      assert List.last(cooldowns) == 300_000
    end

    test "a successful probe resets the cooldown, so the next outage starts fresh" do
      {_, {breaker, elapsed}} = probe_and_fail(3)
      assert Breaker.cooldown(breaker, @opts) == 240_000

      elapsed = elapsed + Breaker.cooldown(breaker, @opts)
      {:probe, probing} = Breaker.allow?(breaker, after_ms(elapsed))
      probing = Breaker.probe_dispatched(probing)
      recovered = Breaker.record_success(probing, @opts)

      assert recovered.state == :closed
      assert Breaker.cooldown(recovered, @opts) == 30_000
      assert recovered.trips == 0
    end
  end

  describe "time_until_probe/2" do
    test "counts down while open" do
      breaker = fail_times(new(), 5)

      assert Breaker.time_until_probe(breaker, @now) == 30_000
      assert Breaker.time_until_probe(breaker, after_ms(10_000)) == 20_000
      assert Breaker.time_until_probe(breaker, after_ms(30_000)) == 0
      assert Breaker.time_until_probe(breaker, after_ms(99_000)) == 0
    end

    test "is zero when closed" do
      assert Breaker.time_until_probe(new(), @now) == 0
    end
  end
end
