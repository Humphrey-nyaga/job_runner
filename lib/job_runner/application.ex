defmodule JobRunner.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        JobRunnerWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:job_runner, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: JobRunner.PubSub}
      ] ++
        jobs_subsystem() ++
        [
          # Start to serve requests, typically the last entry
          JobRunnerWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: JobRunner.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The job subsystem sits after PubSub (the Store broadcasts on every write)
  # and before the Endpoint (so the dashboard can never render against a
  # subsystem that has not started).
  #
  # Tests opt out and start their own tree instead: each test then gets a fresh
  # Store with empty ETS tables, and can kill the Queue without disturbing other
  # tests. Fault-tolerance tests need to kill supervised processes on purpose,
  # which is only safe when the tree belongs to the test.
  defp jobs_subsystem do
    if Application.get_env(:job_runner, :start_jobs, true) do
      [JobRunner.Jobs.Supervisor]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    JobRunnerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
