defmodule JobRunnerWeb.PageController do
  use JobRunnerWeb, :controller

  @doc """
  Landing page: what this is, how to drive it, and what to try.

  It reads the live configuration rather than hardcoding it, so the numbers on
  screen are the ones actually in force — including any `.env` or shell
  overrides. A guide that can drift out of step with the system it documents is
  worse than no guide.
  """
  def home(conn, _params) do
    render(conn, :home,
      llm: JobRunner.LLM.config(),
      jobs_config: Application.get_env(:job_runner, :jobs, [])
    )
  end
end
