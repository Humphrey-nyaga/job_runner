defmodule JobRunner.Jobs.ExecutionSupervisor do
  @moduledoc """
  Supervises the mutually dependent pair: the `Task.Supervisor` that runs jobs,
  and the `Queue` that dispatches through it.

  `:one_for_all`, because neither is meaningful alone — a dead Queue leaves
  tasks with nowhere to return their results, and a dead `Task.Supervisor`
  leaves the Queue's in-flight accounting describing dead pids.

  Child order is significant: `Task.Supervisor` starts first, because the Queue
  dispatches through it.

  `:max_children` mirrors `max_concurrency`, making the ceiling structural. If
  the Queue's accounting were ever wrong, the supervisor refuses the child
  rather than opening unbounded connections to a shared endpoint.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, config(:max_concurrency, 4))

    children = [
      {
        Task.Supervisor,
        # Job tasks are :temporary — a finished job stays finished, and retry is
        # the Queue's business, not a supervisor's.
        name: JobRunner.Jobs.TaskSupervisor, max_children: max_concurrency, max_restarts: 0
      },
      {JobRunner.Jobs.Queue, Keyword.put(opts, :max_concurrency, max_concurrency)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp config(key, default) do
    :job_runner |> Application.get_env(:jobs, []) |> Keyword.get(key, default)
  end
end
