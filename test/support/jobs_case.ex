defmodule JobRunner.JobsCase do
  @moduledoc """
  Starts a real job subsystem, owned by the test.

  Each test gets its own supervision tree, which matters for two reasons:
  the Store's ETS tables start empty, and fault-tolerance tests can kill
  supervised processes on purpose without disturbing anything else.

  The tree is the *real* one — `Jobs.Supervisor` with its actual strategies —
  not a hand-assembled approximation. A supervision test that builds its own
  tree proves only that the test's tree works.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import JobRunner.JobsCase

      alias JobRunner.Jobs
      alias JobRunner.Jobs.{Job, Queue, Store}
      alias JobRunner.LLM.{Error, Mock}
    end
  end

  setup tags do
    # Applied BEFORE the tree starts, because some state is captured at init
    # time rather than read per call — the circuit breaker's cooldown, for one.
    # A `setup` block in the test module would run *after* this one and be too
    # late, which is a trap worth having exactly one solution for.
    if overrides = tags[:jobs_config] do
      original = Application.get_env(:job_runner, :jobs)
      Application.put_env(:job_runner, :jobs, Keyword.merge(original, overrides))
      on_exit(fn -> Application.put_env(:job_runner, :jobs, original) end)
    end

    JobRunner.Jobs.Metrics.setup()
    JobRunner.Jobs.Metrics.reset()
    start_supervised!(JobRunner.LLM.Mock)
    JobRunner.LLM.Mock.script(tags[:script] || [{:ok, "mock response"}])

    start_supervised!(
      {JobRunner.Jobs.Supervisor,
       max_concurrency: tags[:max_concurrency] || 4, llm_opts: tags[:llm_opts] || []}
    )

    :ok
  end

  @doc """
  Block until `fun` returns truthy, or fail after `timeout`.

  Preferred over `Process.sleep/1`: it fails fast when the condition holds
  early, and reports what it was still waiting for when it does not.
  """
  def eventually(fun, timeout \\ 2_000, interval \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, interval)
  end

  defp do_eventually(fun, deadline, interval) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          ExUnit.Assertions.flunk("condition not met within timeout")
        else
          Process.sleep(interval)
          do_eventually(fun, deadline, interval)
        end
    end
  end

  @doc """
  In-flight count that tolerates the Queue being mid-restart.

  Fault-tolerance tests kill the Queue on purpose, so there is a window where
  the name is unregistered. Polling it with a bare `GenServer.call` turns that
  expected window into a test failure.
  """
  def safe_in_flight do
    JobRunner.Jobs.Queue.in_flight_count()
  catch
    :exit, _ -> nil
  end

  @doc "Wait for a job to reach one of `statuses`, returning the job."
  def await_status(job_id, statuses, timeout \\ 2_000) do
    statuses = List.wrap(statuses)

    eventually(
      fn ->
        case JobRunner.Jobs.Store.fetch(job_id) do
          {:ok, job} -> if job.status in statuses, do: job, else: nil
          _ -> nil
        end
      end,
      timeout
    )
  end
end
