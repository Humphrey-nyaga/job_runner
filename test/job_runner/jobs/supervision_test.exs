defmodule JobRunner.Jobs.SupervisionTest do
  @moduledoc """
  Fault tolerance.

  These are the brief's success metrics, so they kill real supervised processes
  in the real tree rather than asserting on a diagram. The highest-value test here kills the Queue with jobs in flight and proves
  nothing is left stranded in `:running`.
  """

  use JobRunner.JobsCase, async: false

  @moduletag :capture_log

  alias JobRunner.Jobs.{ExecutionSupervisor, Supervisor, TaskSupervisor}

  describe "tree shape" do
    # which_children/1 returns children in REVERSE start order, so these are
    # reversed to assert the order they actually start in.
    defp start_order(supervisor) do
      supervisor
      |> Elixir.Supervisor.which_children()
      |> Enum.reverse()
      |> Enum.map(fn {id, pid, type, _modules} -> {id, is_pid(pid), type} end)
    end

    test "child order is correct" do
      # The Store starts first and so outlives the execution subtree under
      # rest_for_one — its data is what recovery depends on.
      assert [
               {JobRunner.Jobs.Store, true, :worker},
               {ExecutionSupervisor, true, :supervisor}
             ] = start_order(Supervisor)

      # The Task.Supervisor starts before the Queue that dispatches through it.
      # Reversing these is the flaw the first draft of had.
      assert [
               {TaskSupervisor, true, :supervisor},
               {JobRunner.Jobs.Queue, true, :worker}
             ] = start_order(ExecutionSupervisor)
    end

    @tag max_concurrency: 2
    test "the concurrency ceiling is enforced structurally, not only by the Queue" do
      # If a Queue accounting bug ever let it over-dispatch, the supervisor
      # refuses the child rather than opening unbounded sockets to a shared
      # endpoint. Asserted behaviourally by trying to exceed it directly.
      for _ <- 1..2 do
        assert {:ok, _pid} =
                 Task.Supervisor.start_child(TaskSupervisor, fn -> Process.sleep(500) end)
      end

      assert {:error, :max_children} =
               Task.Supervisor.start_child(TaskSupervisor, fn -> :ok end)
    end
  end

  describe "killing the Queue" do
    test "no job is left stranded in :running" do
      # First attempt hangs long enough to be killed mid-flight; every attempt
      # after that succeeds quickly.
      Mock.script([
        {:sleep, 3_000, {:ok, "killed before this"}},
        {:sleep, 3_000, {:ok, "killed before this"}},
        {:sleep, 3_000, {:ok, "killed before this"}},
        {:sleep, 3_000, {:ok, "killed before this"}},
        {:ok, "completed after recovery"}
      ])

      ids = for n <- 1..4, do: elem(Jobs.add_job("job #{n}"), 1)
      eventually(fn -> safe_in_flight() == 4 end)
      assert Store.count_by_status().running == 4

      Process.exit(Process.whereis(Queue), :kill)

      # The invariant is *not* "running momentarily hits zero" — reconciliation
      # makes jobs runnable again immediately, so running can go 4 → 0 → 4
      # faster than any poll can observe. The invariant is that no job is
      # abandoned: every one must reach a terminal state.
      #
      # A restart that only re-enqueued :pending jobs would leave these four
      # :running forever — a permanent lie in the API the brief asks to be
      # queryable. That is the bug exists to prevent.
      for id <- ids do
        job = await_status(id, :completed, 10_000)
        assert job.result == "completed after recovery"

        # And the interruption is on the record rather than being silently
        # swallowed, so a restart is diagnosable after the fact.
        assert Enum.any?(job.history, &(&1.outcome == :interrupted))
      end

      assert Store.count_by_status().running == 0
    end

    test "the Store's data survives, and the Queue comes back" do
      Mock.script([{:sleep, 2_000, {:ok, "slow"}}])
      {:ok, id} = Jobs.add_job("in flight")
      eventually(fn -> safe_in_flight() == 1 end)

      store_pid = Process.whereis(Store)
      queue_pid = Process.whereis(Queue)

      Process.exit(queue_pid, :kill)
      eventually(fn -> is_pid(Process.whereis(Queue)) and Process.whereis(Queue) != queue_pid end)

      # rest_for_one: the Store is upstream, so it is untouched. Its data is
      # exactly what recovery depends on.
      assert Process.whereis(Store) == store_pid
      assert {:ok, %Job{}} = Store.fetch(id)
    end

    test "interrupted jobs resume and complete, without spending budget" do
      Mock.script([{:sleep, 800, {:ok, "eventually done"}}])
      {:ok, id} = Jobs.add_job("interrupted then finishes")

      eventually(fn -> safe_in_flight() == 1 end)
      Process.exit(Process.whereis(Queue), :kill)

      job = await_status(id, :completed, 6_000)

      assert job.result == "eventually done"
      # Two dispatches happened, but the interrupted one was refunded: the
      # attempt died for our reasons, not the endpoint's.
      assert job.attempts == 1
      assert Enum.any?(job.history, &(&1.outcome == :interrupted))
    end

    test "the concurrency ceiling is intact after a restart" do
      Mock.script([{:sleep, 1_500, {:ok, "slow"}}])
      for n <- 1..4, do: Jobs.add_job("job #{n}")
      eventually(fn -> safe_in_flight() == 4 end)

      Process.exit(Process.whereis(Queue), :kill)

      # In-flight is rebuilt as zero — no task survived — then refilled up to
      # the ceiling and no further. safe_in_flight/0 tolerates the restart
      # window, during which the Queue name is briefly unregistered.
      eventually(fn -> safe_in_flight() not in [nil, 0] end, 3_000)

      samples =
        for _ <- 1..20 do
          Process.sleep(10)
          safe_in_flight()
        end

      assert samples |> Enum.reject(&is_nil/1) |> Enum.max() <= 4
    end
  end

  describe "killing the Store" do
    test "rest_for_one restarts the execution subtree too" do
      {:ok, _id} = Jobs.add_job("before the crash")
      queue_pid = Process.whereis(Queue)

      Process.exit(Process.whereis(Store), :kill)

      # The Queue must not survive the loss of the tables it reads: it would be
      # holding job ids that no longer resolve. Silent corruption is worse than
      # a crash.
      eventually(fn ->
        new_pid = Process.whereis(Queue)
        is_pid(new_pid) and new_pid != queue_pid
      end)

      # Tables died with their owner, so the system comes back empty but sane.
      assert Store.all() == []
      assert {:ok, id} = Jobs.add_job("after the crash")
      assert %Job{status: :completed} = await_status(id, :completed)
    end
  end

  describe "metrics outlive the processes that write them" do
    test "a Store restart does not reset lifetime counters" do
      # Metrics.setup/0 runs in Store.init/1, so a non-idempotent setup would
      # silently turn "processed since boot" into "since the last crash".
      Mock.script([{:ok, "done"}])
      {:ok, id} = Jobs.add_job("counted")
      await_status(id, :completed)

      before = JobRunner.Jobs.Metrics.get(:enqueued)
      assert before > 0

      Process.exit(Process.whereis(Store), :kill)
      eventually(fn -> is_pid(Process.whereis(Store)) end)

      assert JobRunner.Jobs.Metrics.get(:enqueued) >= before
    end
  end

  describe "killing the Task.Supervisor" do
    test "one_for_all restarts the Queue with it" do
      Mock.script([{:sleep, 2_000, {:ok, "slow"}}])
      {:ok, _} = Jobs.add_job("in flight")
      eventually(fn -> safe_in_flight() == 1 end)

      queue_pid = Process.whereis(Queue)
      Process.exit(Process.whereis(TaskSupervisor), :kill)

      # The Queue's in-flight map now describes dead pids, so its accounting is
      # fiction. It has to restart with its supervisor.
      eventually(fn ->
        new_pid = Process.whereis(Queue)
        is_pid(new_pid) and new_pid != queue_pid
      end)

      assert Queue.in_flight_count() >= 0
    end
  end

  describe "surviving tasks cannot outlive their Queue" do
    test "killing the Queue also kills its in-flight tasks" do
      # async_nolink tasks are unlinked from the Queue, so it is worth proving
      # they do not outlive it — survivors would mean duplicate LLM calls and a
      # breached concurrency ceiling. The :one_for_all nesting prevents it.
      Mock.script([{:sleep, 5_000, {:ok, "slow"}}])
      for n <- 1..4, do: Jobs.add_job("job #{n}")
      eventually(fn -> safe_in_flight() == 4 end)

      task_pids =
        TaskSupervisor |> Elixir.Supervisor.which_children() |> Enum.map(fn {_, p, _, _} -> p end)

      assert length(task_pids) == 4

      Process.exit(Process.whereis(Queue), :kill)
      eventually(fn -> Enum.all?(task_pids, &(not Process.alive?(&1))) end, 3_000)

      assert Enum.count(task_pids, &Process.alive?/1) == 0
    end
  end

  describe "killing a task directly" do
    test "the Queue records it and carries on" do
      Mock.script([{:sleep, 2_000, {:ok, "slow"}}])
      {:ok, id} = Jobs.add_job("about to be killed")
      eventually(fn -> safe_in_flight() == 1 end)

      queue_pid = Process.whereis(Queue)
      [{_, task_pid, _, _}] = Elixir.Supervisor.which_children(TaskSupervisor)
      Process.exit(task_pid, :kill)

      # async_nolink means this arrives as a :DOWN message, not as our death.
      eventually(fn -> safe_in_flight() == 0 end)
      assert Process.whereis(Queue) == queue_pid

      {:ok, job} = Store.fetch(id)
      assert job.status in [:pending, :running, :failed]
    end
  end

  describe "reconciliation is idempotent" do
    test "surviving two Queue restarts in a row" do
      Mock.script([{:sleep, 600, {:ok, "done"}}])
      {:ok, id} = Jobs.add_job("twice interrupted")

      for _ <- 1..2 do
        eventually(fn -> safe_in_flight() == 1 end, 3_000)
        Process.exit(Process.whereis(Queue), :kill)
        Process.sleep(50)
      end

      job = await_status(id, :completed, 8_000)

      # Both interruptions were refunded, so the job still had its full budget.
      assert job.attempts == 1
      assert Enum.count(job.history, &(&1.outcome == :interrupted)) == 2
    end
  end
end
