defmodule JobRunner.Jobs.StoreTest do
  @moduledoc """
  The Store is the single write path, so it is where the system's invariants are
  actually enforced. These tests assert the enforcement rather than the
  documentation of it.
  """

  use ExUnit.Case, async: false

  alias JobRunner.Jobs.{Job, Store}
  alias JobRunner.LLM.Error

  setup do
    # Tables die with the owner, so a fresh Store per test is a clean slate.
    start_supervised!(Store)
    :ok
  end

  defp insert!(attrs \\ %{}) do
    {:ok, job} = Job.new(Map.merge(%{prompt: "test prompt"}, attrs))
    {:ok, job} = Store.insert(job)
    job
  end

  defp error, do: Error.timeout()

  describe "insert/1" do
    test "admits a job as pending" do
      job = insert!()
      assert {:ok, %Job{status: :pending, attempts: 0}} = Store.fetch(job.id)
    end

    test "rejects a duplicate id" do
      job = insert!()
      assert {:error, :already_exists} = Store.insert(job)
    end

    test "enforces admission backpressure at max_pending_jobs" do
      # Bounding concurrency protects the endpoint; only bounding admission
      # protects the VM. This is checked in the single write path so that
      # concurrent callers cannot race past it.
      original = Application.get_env(:job_runner, :jobs)
      Application.put_env(:job_runner, :jobs, Keyword.put(original, :max_pending_jobs, 3))
      on_exit(fn -> Application.put_env(:job_runner, :jobs, original) end)

      for _ <- 1..3, do: insert!()

      {:ok, extra} = Job.new(%{prompt: "one too many"})
      assert {:error, :queue_full} = Store.insert(extra)
    end

    test "completed jobs do not count against the admission bound" do
      original = Application.get_env(:job_runner, :jobs)
      Application.put_env(:job_runner, :jobs, Keyword.put(original, :max_pending_jobs, 2))
      on_exit(fn -> Application.put_env(:job_runner, :jobs, original) end)

      job = insert!()
      {:ok, running} = Store.start_attempt(job.id)
      {:ok, _} = Store.complete(job.id, running.attempt_id, "done")

      # The finished job freed its slot.
      assert %Job{} = insert!()
    end
  end

  describe "start_attempt/1" do
    test "mints the token inside the write path and spends budget" do
      job = insert!()

      assert {:ok, %Job{status: :running, attempts: 1, attempt_id: 1}} =
               Store.start_attempt(job.id)
    end

    test "the token advances on every dispatch" do
      job = insert!()
      {:ok, a} = Store.start_attempt(job.id)
      {:ok, _} = Store.schedule_retry(job.id, a.attempt_id, DateTime.utc_now(), 500, error())
      {:ok, b} = Store.start_attempt(job.id)

      assert b.attempt_id == a.attempt_id + 1
    end

    test "permits exactly max_attempts dispatches" do
      job = insert!(%{max_attempts: 3})

      for _ <- 1..3 do
        {:ok, r} = Store.start_attempt(job.id)
        {:ok, _} = Store.schedule_retry(job.id, r.attempt_id, DateTime.utc_now(), 1, error())
      end

      # The budget is spent: a 4th dispatch is refused rather than silently allowed.
      assert {:error, :exhausted} = Store.start_attempt(job.id)
    end

    test "refuses to redispatch a job that is already running" do
      job = insert!()
      {:ok, _} = Store.start_attempt(job.id)
      assert {:error, :invalid_transition} = Store.start_attempt(job.id)
    end

    test "unknown id" do
      assert {:error, :not_found} = Store.start_attempt("nope")
    end
  end

  describe "only the current attempt may change the job" do
    setup do
      job = insert!()
      {:ok, running} = Store.start_attempt(job.id)
      {:ok, job: job, attempt_id: running.attempt_id}
    end

    test "complete/3 with a stale token is rejected", %{job: job, attempt_id: current} do
      assert {:error, :stale_attempt} = Store.complete(job.id, current - 1, "stale result")
      assert {:ok, %Job{status: :running, result: nil}} = Store.fetch(job.id)
    end

    test "fail/3 with a stale token is rejected", %{job: job, attempt_id: current} do
      assert {:error, :stale_attempt} = Store.fail(job.id, current + 99, error())
      assert {:ok, %Job{status: :running}} = Store.fetch(job.id)
    end

    test "schedule_retry/5 with a stale token is rejected", %{job: job, attempt_id: current} do
      assert {:error, :stale_attempt} =
               Store.schedule_retry(job.id, current - 1, DateTime.utc_now(), 500, error())
    end

    test "the current token is accepted", %{job: job, attempt_id: current} do
      assert {:ok, %Job{status: :completed, result: "ok"}} =
               Store.complete(job.id, current, "ok")
    end

    test "a stale token from a previous attempt cannot kill a later one",
         %{job: job, attempt_id: first} do
      {:ok, _} = Store.schedule_retry(job.id, first, DateTime.utc_now(), 500, error())
      {:ok, second} = Store.start_attempt(job.id)

      # This is the stale-deadline scenario: attempt 1's timeout fires while
      # attempt 2 is healthy and in flight.
      assert {:error, :stale_attempt} = Store.fail(job.id, first, error())

      assert {:ok, %Job{status: :running}} = Store.fetch(job.id)
      assert {:ok, %Job{status: :completed}} = Store.complete(job.id, second.attempt_id, "ok")
    end
  end

  describe "terminal jobs ignore late outcomes" do
    setup do
      job = insert!()
      {:ok, running} = Store.start_attempt(job.id)
      {:ok, _} = Store.complete(job.id, running.attempt_id, "first result")
      {:ok, job: job, attempt_id: running.attempt_id}
    end

    test "a duplicate completion changes nothing", %{job: job, attempt_id: id} do
      assert {:error, :invalid_transition} = Store.complete(job.id, id, "second result")
      assert {:ok, %Job{result: "first result"}} = Store.fetch(job.id)
    end

    test "a late failure cannot un-complete the job", %{job: job, attempt_id: id} do
      assert {:error, :invalid_transition} = Store.fail(job.id, id, error())
      assert {:ok, %Job{status: :completed}} = Store.fetch(job.id)
    end
  end

  describe "interruption" do
    test "refunds budget but still advances the generation token" do
      job = insert!()
      {:ok, first} = Store.start_attempt(job.id)

      {:ok, interrupted} = Store.mark_interrupted(job.id)
      assert interrupted.status == :pending
      # The attempt died for our reasons, not the endpoint's, so it is not charged.
      assert interrupted.attempts == first.attempts - 1
      # But the next dispatch must remain distinguishable from the killed one.
      assert interrupted.attempt_id == first.attempt_id

      {:ok, second} = Store.start_attempt(job.id)
      assert second.attempt_id > first.attempt_id
      assert {:error, :stale_attempt} = Store.complete(job.id, first.attempt_id, "zombie")
    end

    test "records the interruption in history" do
      job = insert!()
      {:ok, _} = Store.start_attempt(job.id)
      {:ok, interrupted} = Store.mark_interrupted(job.id)

      assert [%{outcome: :interrupted, finished_at: %DateTime{}} | _] = interrupted.history
    end

    test "is idempotent — reconciliation may run more than once" do
      job = insert!()
      {:ok, _} = Store.start_attempt(job.id)

      {:ok, once} = Store.mark_interrupted(job.id)
      {:ok, twice} = Store.mark_interrupted(job.id)

      assert once.attempts == twice.attempts
      assert length(once.history) == length(twice.history)
    end

    test "leaves terminal jobs alone" do
      job = insert!()
      {:ok, r} = Store.start_attempt(job.id)
      {:ok, _} = Store.complete(job.id, r.attempt_id, "done")

      assert {:ok, %Job{status: :completed, result: "done"}} = Store.mark_interrupted(job.id)
    end
  end

  describe "dead letter queue" do
    setup do
      job = insert!(%{max_attempts: 2})

      for _ <- 1..1 do
        {:ok, r} = Store.start_attempt(job.id)
        {:ok, _} = Store.schedule_retry(job.id, r.attempt_id, DateTime.utc_now(), 500, error())
      end

      {:ok, last} = Store.start_attempt(job.id)
      {:ok, dead} = Store.fail(job.id, last.attempt_id, error())
      {:ok, job: job, dead: dead}
    end

    test "the dead-lettered job carries one history entry per attempt", %{dead: dead} do
      assert dead.status == :failed
      assert dead.dead_lettered_at
      assert length(dead.history) == 2

      # Newest first; the recorded backoff is what makes a failure diagnosable
      # after the fact rather than just a log line.
      assert [%{attempt_no: 2, outcome: :error}, %{attempt_no: 1, backoff_ms: 500}] = dead.history
    end

    test "appears in dead_letters/0", %{job: job} do
      assert [%Job{id: id}] = Store.dead_letters()
      assert id == job.id
    end

    test "requeue/1 restores a fresh budget and clears the DLQ", %{job: job} do
      assert {:ok, requeued} = Store.requeue(job.id)

      assert requeued.status == :pending
      assert requeued.attempts == 0
      assert requeued.dead_lettered_at == nil
      assert Store.dead_letters() == []

      # History is deliberately kept: the point of a replay is to know it is one.
      assert length(requeued.history) == 2
    end

    test "requeue/1 refuses a job that is not dead-lettered" do
      live = insert!()
      assert {:error, :not_dead_lettered} = Store.requeue(live.id)
    end
  end

  describe "reads and writes across process boundaries" do
    test "another process may read directly, without a message to the owner" do
      job = insert!()

      assert {:ok, %Job{}} = Task.await(Task.async(fn -> Store.fetch(job.id) end))
    end

    test "another process may NOT write — the table is :protected" do
      insert!()

      result =
        Task.async(fn ->
          try do
            :ets.insert(:job_runner_jobs, {"forged", :arbitrary})
            :wrote
          rescue
            ArgumentError -> :rejected
          end
        end)
        |> Task.await()

      # If this ever returns :wrote, transition validation has been bypassable
      # and every guarantee is void.
      assert result == :rejected
    end
  end

  describe "queries" do
    test "count_by_status/0 always reports all four statuses" do
      assert %{pending: 0, running: 0, completed: 0, failed: 0} = Store.count_by_status()

      job = insert!()
      assert %{pending: 1} = Store.count_by_status()

      {:ok, r} = Store.start_attempt(job.id)
      assert %{pending: 0, running: 1} = Store.count_by_status()

      {:ok, _} = Store.complete(job.id, r.attempt_id, "x")
      assert %{running: 0, completed: 1} = Store.count_by_status()
    end

    test "non_terminal/0 is the input to recovery reconciliation" do
      pending = insert!()
      running = insert!()
      done = insert!()

      {:ok, _} = Store.start_attempt(running.id)
      {:ok, r} = Store.start_attempt(done.id)
      {:ok, _} = Store.complete(done.id, r.attempt_id, "x")

      ids = Store.non_terminal() |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.equal?(ids, MapSet.new([pending.id, running.id]))
    end

    test "pending_breakdown/0 separates runnable work from backoff waiting" do
      # The two are conflated by `:pending` alone, and they mean opposite things
      # operationally: one is work the queue could start right now, the other is
      # work deliberately parked on a timer holding no slot.
      runnable = insert!()
      waiting = insert!()

      {:ok, attempt} = Store.start_attempt(waiting.id)

      {:ok, _} =
        Store.schedule_retry(
          waiting.id,
          attempt.attempt_id,
          DateTime.add(DateTime.utc_now(), 60, :second),
          60_000,
          error()
        )

      assert %{runnable: 1, scheduled: 1} = Store.pending_breakdown()

      # And it always reconciles with the headline number.
      breakdown = Store.pending_breakdown()
      assert breakdown.runnable + breakdown.scheduled == Store.count_by_status().pending

      assert {:ok, %Job{status: :pending, next_run_at: nil}} = Store.fetch(runnable.id)
    end

    test "a backoff that has already elapsed counts as runnable again" do
      job = insert!()
      {:ok, attempt} = Store.start_attempt(job.id)

      {:ok, _} =
        Store.schedule_retry(
          job.id,
          attempt.attempt_id,
          DateTime.add(DateTime.utc_now(), -1, :second),
          500,
          error()
        )

      assert %{runnable: 1, scheduled: 0} = Store.pending_breakdown()
    end

    test "terminal and running jobs are excluded from the breakdown" do
      running = insert!()
      done = insert!()

      {:ok, _} = Store.start_attempt(running.id)
      {:ok, attempt} = Store.start_attempt(done.id)
      {:ok, _} = Store.complete(done.id, attempt.attempt_id, "x")

      assert %{runnable: 0, scheduled: 0} = Store.pending_breakdown()
    end

    test "fetch/1 on an unknown id" do
      assert {:error, :not_found} = Store.fetch("does-not-exist")
    end

    test "all/0 returns newest first" do
      a = insert!()
      Process.sleep(2)
      b = insert!()

      assert [%Job{id: first}, %Job{id: second}] = Store.all()
      assert first == b.id
      assert second == a.id
    end
  end

  describe "PubSub" do
    test "every write broadcasts the updated job" do
      Store.subscribe()

      job = insert!()
      assert_receive {:job_updated, %Job{id: id, status: :pending}}
      assert id == job.id

      {:ok, r} = Store.start_attempt(job.id)
      assert_receive {:job_updated, %Job{status: :running}}

      {:ok, _} = Store.complete(job.id, r.attempt_id, "x")
      assert_receive {:job_updated, %Job{status: :completed}}
    end

    test "a rejected write broadcasts nothing" do
      job = insert!()
      {:ok, _} = Store.start_attempt(job.id)
      Store.subscribe()

      assert {:error, :stale_attempt} = Store.complete(job.id, 999, "x")
      refute_receive {:job_updated, _}, 50
    end
  end
end
