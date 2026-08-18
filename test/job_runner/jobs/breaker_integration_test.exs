defmodule JobRunner.Jobs.BreakerIntegrationTest do
  @moduledoc """
  The breaker inside the running system.

  `breaker_test.exs` proves the state machine. These prove the thing that
  actually matters operationally: **an outage costs time, not jobs.** Without a
  breaker, each of these ends with a drained queue and a full dead letter queue.
  """

  use JobRunner.JobsCase, async: false

  @moduletag :capture_log

  alias JobRunner.Jobs.Breaker

  # Small threshold and cooldown so an outage-and-recovery cycle runs in
  # milliseconds rather than minutes.
  #
  # This must be a moduletag rather than a `setup` block: the Store builds the
  # breaker in init/1, so the config has to be in place before the tree starts.
  # JobsCase applies `:jobs_config` at the right moment.
  @moduletag jobs_config: [
               breaker_threshold: 3,
               breaker_cooldown_ms: 200,
               breaker_max_cooldown_ms: 800
             ]

  defp outage, do: Mock.script([{:error, Error.transport(:econnrefused)}])

  describe "an outage costs time, not jobs" do
    test "the breaker opens and dispatch stops" do
      outage()

      for n <- 1..10, do: Jobs.add_job("job #{n}")

      eventually(fn -> Jobs.breaker().state == :open end, 3_000)
      assert Breaker.open?(Jobs.breaker())
    end

    test "queued jobs are NOT dead-lettered during the outage" do
      outage()

      ids = for n <- 1..10, do: elem(Jobs.add_job("job #{n}"), 1)
      eventually(fn -> Jobs.breaker().state == :open end, 3_000)

      # Give the system every chance to misbehave.
      Process.sleep(150)

      untouched =
        ids
        |> Enum.map(&elem(Store.fetch(&1), 1))
        |> Enum.filter(&(&1.attempts == 0))

      # The bound is derived, not guessed. Before the breaker can open, at least
      # `threshold` failures must have occurred, and up to `max_concurrency`
      # calls can already be in flight when the last one lands. So at most
      # threshold + max_concurrency = 3 + 4 = 7 jobs can be touched, leaving 3.
      #
      # This is exactly the guarantee claims and no more: the breaker
      # protects the *undispatched* remainder. Without it, all 10 would grind
      # through five attempts each and land in the DLQ.
      assert length(untouched) >= 10 - (3 + 4)
      assert Enum.all?(untouched, &(&1.status == :pending))
    end

    test "the adapter stops being called once the breaker is open" do
      outage()

      for n <- 1..10, do: Jobs.add_job("job #{n}")
      eventually(fn -> Jobs.breaker().state == :open end, 3_000)

      # Load against a failing endpoint drops to at most one probe per cooldown,
      # instead of max_concurrency calls in a hot retry loop.
      calls_when_opened = Mock.call_count()
      Process.sleep(100)

      assert Mock.call_count() == calls_when_opened
    end
  end

  describe "recovery" do
    test "the endpoint comes back and the whole backlog completes, DLQ empty" do
      outage()
      ids = for n <- 1..8, do: elem(Jobs.add_job("job #{n}"), 1)

      eventually(fn -> Jobs.breaker().state == :open end, 3_000)

      # Endpoint recovers.
      Mock.script([{:ok, "recovered"}])

      # The half-open probe closes the breaker with no operator action.
      eventually(fn -> Jobs.breaker().state == :closed end, 5_000)

      for id <- ids do
        job = await_status(id, :completed, 10_000)
        assert job.result == "recovered"
      end

      # The entire point: an outage cost time, and nothing else.
      assert Jobs.dead_letters() == []
    end

    test "only one probe is dispatched while half-open" do
      outage()
      for n <- 1..8, do: Jobs.add_job("job #{n}")
      eventually(fn -> Jobs.breaker().state == :open end, 3_000)

      # Slow success, so the probe is observably in flight.
      Mock.script([{:sleep, 400, {:ok, "recovered"}}])

      eventually(fn -> Queue.in_flight_count() == 1 end, 3_000)

      # An endpoint that has only just come back must not be met with the whole
      # backlog at once.
      samples =
        for _ <- 1..15,
            do:
              (
                Process.sleep(10)
                Queue.in_flight_count()
              )

      assert Enum.max(samples) == 1
    end
  end

  describe "what must not trip it, end to end" do
    test "a stream of permanent failures never opens the breaker" do
      Mock.script([{:error, Error.http_status(400, "bad prompt")}])

      ids = for n <- 1..10, do: elem(Jobs.add_job("job #{n}"), 1)
      for id <- ids, do: await_status(id, :failed, 5_000)

      # Ten bad prompts is not an outage. Every job failed on its own merits and
      # the system stayed open for business.
      assert Jobs.breaker().state == :closed
      assert length(Jobs.dead_letters()) == 10
    end

    test "a model returning garbage never opens the breaker" do
      Mock.script([{:error, Error.malformed_response("<html>not json</html>")}])

      {:ok, id} = Jobs.add_job("job")
      await_status(id, :failed, 10_000)

      # The server answered promptly and correctly at the HTTP layer — it is
      # healthy. Only the generation was unusable.
      assert Jobs.breaker().state == :closed
    end

    test "healthy traffic interleaved with failures keeps it closed" do
      Mock.script([
        {:error, Error.timeout()},
        {:ok, "fine"},
        {:error, Error.timeout()},
        {:ok, "fine"},
        {:error, Error.timeout()},
        {:ok, "fine"}
      ])

      ids = for n <- 1..3, do: elem(Jobs.add_job("job #{n}"), 1)
      for id <- ids, do: await_status(id, :completed, 5_000)

      # Three systemic failures with the threshold at three — but never three
      # *consecutively*, because each success resets the count. This is the
      # guard that stops one flaky job stalling healthy traffic.
      assert Jobs.breaker().state == :closed
    end
  end

  describe "recovery is not blocked by exhausted jobs" do
    test "a queue whose head jobs are spent still recovers" do
      # The Queue can grant a probe and then find the chosen job exhausted, so
      # nothing is dispatched. Were the probe marked in-flight on the grant, the
      # breaker would wait forever for a verdict that could never arrive, and
      # every remaining job would be denied indefinitely.
      outage()

      # Let some jobs burn all the way through their budgets.
      spent = for n <- 1..3, do: elem(Jobs.add_job("spent #{n}"), 1)
      for id <- spent, do: await_status(id, :failed, 20_000)

      # Now a fresh batch arrives while the endpoint is still down.
      fresh = for n <- 1..4, do: elem(Jobs.add_job("fresh #{n}"), 1)
      eventually(fn -> Jobs.breaker().state == :open end, 5_000)

      Mock.script([{:ok, "recovered"}])

      for id <- fresh do
        assert %Job{status: :completed} = await_status(id, :completed, 20_000)
      end

      assert Jobs.breaker().state == :closed
    end
  end

  describe "the breaker survives a Queue restart" do
    test "an outage is not forgotten because the scheduler blinked" do
      outage()
      for n <- 1..6, do: Jobs.add_job("job #{n}")
      eventually(fn -> Jobs.breaker().state == :open end, 3_000)

      Process.exit(Process.whereis(Queue), :kill)
      eventually(fn -> is_pid(Process.whereis(Queue)) end)

      # State lives in the Store's ETS, which is upstream of the execution
      # subtree under rest_for_one. A restarted Queue inherits the outage rather
      # than rediscovering it by hammering the endpoint another 3 times.
      assert Jobs.breaker().state in [:open, :half_open]
    end
  end

  describe "observability" do
    test "stats/0 exposes breaker state, so an idle system is explicable" do
      outage()
      for n <- 1..6, do: Jobs.add_job("job #{n}")
      eventually(fn -> Jobs.breaker().state == :open end, 3_000)

      stats = Jobs.stats()

      # "Why is nothing running?" must have a visible answer rather than looking
      # like a hang.
      assert stats.breaker == :open
      assert stats.pending > 0
      assert stats.in_flight == 0
    end

    test "a transition is broadcast to subscribers" do
      Jobs.subscribe()
      outage()
      for n <- 1..6, do: Jobs.add_job("job #{n}")

      assert_receive {:breaker_changed, %Breaker{state: :open}}, 3_000
    end
  end
end
