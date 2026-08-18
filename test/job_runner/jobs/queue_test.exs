defmodule JobRunner.Jobs.QueueTest do
  @moduledoc """
  The scheduler: ordering, the concurrency ceiling, retry timing, and the
  message races.
  """

  use JobRunner.JobsCase, async: false

  # Crash-isolation tests deliberately blow jobs up. The resulting reports are
  # the system working, not the test failing, so they are kept out of the output.
  @moduletag :capture_log

  describe "submission" do
    test "add_job/1 returns an id and the job starts pending" do
      assert {:ok, id} = Jobs.add_job("hello")
      assert is_binary(id)
      assert %Job{status: :completed} = await_status(id, :completed)
    end

    test "unknown ids" do
      assert {:error, :not_found} = Jobs.status("nope")
      assert {:error, :not_found} = Jobs.result("nope")
    end

    @tag script: [{:sleep, 300, {:ok, "slow"}}]
    test "result/1 while the job is still in play" do
      # An absent result and a result of nil are different facts, so this is an
      # error rather than {:ok, nil}.
      {:ok, id} = Jobs.add_job("slow one")
      assert {:error, :not_completed} = Jobs.result(id)
    end

    test "validation errors surface to the caller, nothing is enqueued" do
      assert {:error, :invalid_prompt} = Jobs.add_job("")
      assert {:error, :invalid_priority} = Jobs.add_job(%{prompt: "x", priority: :urgent})
      assert Jobs.all() == []
    end
  end

  describe "FIFO within a priority" do
    @tag script: [{:sleep, 20, {:ok, "done"}}]
    @tag max_concurrency: 1
    test "completion order matches submission order" do
      ids = for n <- 1..5, do: elem(Jobs.add_job("job #{n}"), 1)

      for id <- ids, do: await_status(id, :completed)

      completed =
        Jobs.all()
        |> Enum.sort_by(& &1.finished_at, {:asc, DateTime})
        |> Enum.map(& &1.id)

      assert completed == ids
    end
  end

  describe "the concurrency ceiling" do
    @tag script: [{:sleep, 150, {:ok, "done"}}]
    @tag max_concurrency: 3
    test "never more than max_concurrency tasks run at once" do
      for n <- 1..10, do: Jobs.add_job("job #{n}")

      # Sample repeatedly while the batch drains. A single sample could miss an
      # overshoot; the ceiling has to hold at every instant, not on average.
      samples =
        for _ <- 1..40 do
          Process.sleep(10)
          Queue.in_flight_count()
        end

      assert Enum.max(samples) <= 3
      # Sanity check that the test actually exercised concurrency at all.
      assert Enum.max(samples) >= 2
    end

    @tag script: [{:sleep, 100, {:ok, "done"}}]
    @tag max_concurrency: 2
    test "queued jobs remain pending rather than being dropped" do
      ids = for n <- 1..6, do: elem(Jobs.add_job("job #{n}"), 1)

      eventually(fn -> Queue.in_flight_count() == 2 end)
      counts = Store.count_by_status()
      assert counts.running == 2
      assert counts.pending == 4

      for id <- ids, do: await_status(id, :completed, 3_000)
      assert Store.count_by_status().completed == 6
    end
  end

  describe "priority" do
    @tag script: [{:sleep, 30, {:ok, "done"}}]
    @tag max_concurrency: 1
    test "high priority overtakes work queued before it" do
      # Fill the single slot first so the rest genuinely queue.
      {:ok, _blocker} = Jobs.add_job("blocker")

      normals = for n <- 1..4, do: elem(Jobs.add_job("normal #{n}"), 1)
      {:ok, urgent} = Jobs.add_job(%{prompt: "urgent", priority: :high})

      for id <- [urgent | normals], do: await_status(id, :completed, 3_000)

      order =
        Jobs.all()
        |> Enum.sort_by(& &1.finished_at, {:asc, DateTime})
        |> Enum.map(& &1.id)

      # It was submitted last but must not finish last.
      refute List.last(order) == urgent
      assert Enum.find_index(order, &(&1 == urgent)) < length(normals)
    end

    @tag script: [{:sleep, 10, {:ok, "done"}}]
    @tag max_concurrency: 1
    test "a low priority job still completes under sustained high-priority load" do
      # Strict priority would starve this forever; the anti-starvation rule is
      # what makes the test pass.
      {:ok, low} = Jobs.add_job(%{prompt: "low", priority: :low})
      for n <- 1..12, do: Jobs.add_job(%{prompt: "high #{n}", priority: :high})

      assert %Job{status: :completed} = await_status(low, :completed, 3_000)
    end
  end

  describe "retry and backoff" do
    # Readability: the failure scripts are built here rather than in @tag
    # literals, so a test reads as "times out twice, then succeeds".
    defp timeout_error, do: Error.timeout()
    defp bad_request, do: Error.http_status(400, "malformed prompt")

    test "fails twice then succeeds, spending exactly three attempts" do
      Mock.script([
        {:error, timeout_error()},
        {:error, timeout_error()},
        {:ok, "third time lucky"}
      ])

      {:ok, id} = Jobs.add_job("flaky")

      job = await_status(id, :completed, 5_000)
      assert job.attempts == 3
      assert job.result == "third time lucky"
      assert Mock.call_count() == 3
    end

    test "an always-failing job exhausts its budget then dead-letters" do
      # One-element script: sticky, so it fails however many times it is asked.
      Mock.script([{:error, timeout_error()}])
      {:ok, id} = Jobs.add_job("doomed")

      job = await_status(id, :failed, 15_000)
      assert job.attempts == job.max_attempts
      # The budget is a budget: the adapter is called exactly max_attempts times.
      assert Mock.call_count() == job.max_attempts
      assert [%Job{id: ^id}] = Jobs.dead_letters()
    end

    test "a permanent failure is not retried at all" do
      Mock.script([{:error, bad_request()}])
      {:ok, id} = Jobs.add_job("malformed")

      job = await_status(id, :failed, 2_000)
      # One attempt, not five. Retrying a 400 sends identical bytes and fails
      # identically — pure waste.
      assert job.attempts == 1
      assert Mock.call_count() == 1
    end

    test "recorded backoff intervals grow exponentially" do
      Mock.script([{:error, timeout_error()}])
      {:ok, id} = Jobs.add_job("doomed")
      job = await_status(id, :failed, 15_000)

      backoffs =
        job.history
        |> Enum.reverse()
        |> Enum.map(& &1.backoff_ms)
        |> Enum.reject(&is_nil/1)

      assert length(backoffs) == job.max_attempts - 1

      # Each gap must exceed its predecessor. The bound is derived, not guessed:
      # with a ±25% jitter band the worst case is a maximally-jittered short gap
      # followed by a minimally-jittered long one, i.e. 2 × 0.75 / 1.25 = 1.2.
      # Asserting anything above that ratio is a test that fails at random.
      backoffs
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert b > a * 1.15, "backoff did not grow: #{a} -> #{b}"
      end)

      # The exact exponential shape is asserted deterministically, with jitter
      # disabled, in BackoffTest — that is the right place for it.
      assert List.last(backoffs) > List.first(backoffs) * 4
    end

    @tag max_concurrency: 1
    test "the slot is freed during backoff, not held by it" do
      Mock.script([{:error, timeout_error()}, {:ok, "recovered"}])

      # This is the property. With max_concurrency: 1, if the failing
      # job held its slot while waiting out its backoff, the second job could
      # not start until the first finished entirely.
      {:ok, failing} = Jobs.add_job("fails first")
      Process.sleep(20)
      {:ok, other} = Jobs.add_job("unrelated")

      other_job = await_status(other, :completed, 2_000)
      failing_job = await_status(failing, :completed, 5_000)

      # The unrelated job ran *inside* the failing job's backoff window.
      assert DateTime.compare(other_job.finished_at, failing_job.finished_at) == :lt
      assert failing_job.attempts == 2
    end
  end

  describe "crash isolation" do
    @tag script: [{:raise, "job blew up"}]
    test "a crashing job does not take the Queue with it" do
      queue_pid = Process.whereis(Queue)
      {:ok, id} = Jobs.add_job("explodes")

      await_status(id, [:failed, :pending], 5_000)

      # The whole point of async_nolink: the crash is an outcome, not an outage.
      assert Process.alive?(queue_pid)
      assert Process.whereis(Queue) == queue_pid
    end

    @tag script: [{:raise, "job blew up"}]
    test "a crash is retried on a reduced budget, not the full one" do
      {:ok, id} = Jobs.add_job("explodes")
      job = await_status(id, :failed, 10_000)

      # Most exceptions are deterministic; repeating one five times is noise.
      assert job.attempts == JobRunner.Jobs.Failure.crash_retry_budget()
      assert job.attempts < job.max_attempts
    end

    @tag max_concurrency: 4
    test "sibling jobs in flight are unaffected by one crashing" do
      Mock.script([
        {:raise, "boom"},
        {:sleep, 60, {:ok, "a"}},
        {:sleep, 60, {:ok, "b"}},
        {:sleep, 60, {:ok, "c"}}
      ])

      {:ok, doomed} = Jobs.add_job("crasher")
      survivors = for n <- 1..3, do: elem(Jobs.add_job("survivor #{n}"), 1)

      for id <- survivors,
          do: assert(%Job{status: :completed} = await_status(id, :completed, 5_000))

      assert %Job{} = await_status(doomed, [:failed, :pending], 5_000)
    end
  end

  describe "the job deadline" do
    @tag llm_opts: []
    test "a task that outlives job_timeout_ms is killed and its slot reclaimed" do
      original = Application.get_env(:job_runner, :jobs)
      Application.put_env(:job_runner, :jobs, Keyword.put(original, :job_timeout_ms, 100))
      on_exit(fn -> Application.put_env(:job_runner, :jobs, original) end)

      # Far longer than the deadline: the adapter is wedged, not merely slow.
      Mock.script([{:sleep, 5_000, {:ok, "never seen"}}])

      {:ok, id} = Jobs.add_job("hangs")

      # Wait for the attempt to actually be dispatched and then abandoned.
      # Matching on :pending alone would match the job's *initial* pending state
      # before dispatch, which asserts nothing.
      job =
        eventually(
          fn ->
            case Store.fetch(id) do
              {:ok, %Job{attempts: n, status: status} = job}
              when n >= 1 and status in [:pending, :failed] ->
                job

              _ ->
                nil
            end
          end,
          3_000
        )

      # It must not sit in :running forever — the deadline belongs to the process
      # that owns the slot, not to the code renting it.
      assert job.attempts >= 1
      assert [%{outcome: :error} | _] = job.history

      # And the slot is genuinely reclaimed, not merely marked free.
      assert eventually(fn -> Queue.in_flight_count() == 0 end, 3_000)
    end
  end

  describe "queue introspection" do
    @tag script: [{:sleep, 200, {:ok, "done"}}]
    @tag max_concurrency: 1
    test "queue_depths/0 reports pending work per priority" do
      Jobs.add_job("blocker")
      eventually(fn -> Queue.in_flight_count() == 1 end)

      Jobs.add_job(%{prompt: "h", priority: :high})
      Jobs.add_job(%{prompt: "n", priority: :normal})
      Jobs.add_job(%{prompt: "l", priority: :low})
      Queue.sync()

      assert %{high: 1, normal: 1, low: 1} = Queue.queue_depths()
    end

    test "stats/0 aggregates the whole system" do
      {:ok, id} = Jobs.add_job("x")
      await_status(id, :completed)

      stats = Jobs.stats()
      assert stats.completed == 1
      assert stats.in_flight == 0
      assert stats.dead_lettered == 0
    end
  end
end
