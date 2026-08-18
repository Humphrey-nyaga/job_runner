defmodule JobRunner.Jobs.Supervisor do
  @moduledoc """
  Root of the job subsystem: `:rest_for_one` over `[Store, ExecutionSupervisor]`.

  The Store owns the ETS tables, so its crash must restart everything below it —
  no process may keep running against a dangling table reference. A crash below
  the Store leaves it intact, which is what makes recovery possible: the
  restarted Queue reads job state back out of it.

  Restart intensity is left at the default 3-in-5, so a crash-looping subsystem
  escalates rather than thrashing against a shared endpoint.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    children = [
      # Started first, and outlives everything below it.
      JobRunner.Jobs.Store,
      # `:name` is dropped: it names *this* supervisor, and passing it down would
      # make the child try to register under the same name.
      {JobRunner.Jobs.ExecutionSupervisor, Keyword.delete(opts, :name)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
