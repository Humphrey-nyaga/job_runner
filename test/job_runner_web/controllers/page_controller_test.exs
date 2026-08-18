defmodule JobRunnerWeb.PageControllerTest do
  use JobRunnerWeb.ConnCase

  test "the landing page orients a reader and links to the dashboard", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "JobRunner"
    assert html =~ "supervised, concurrent, retrying background job system"
    assert html =~ ~s(href="/jobs")
    assert html =~ "Open the dashboard"
  end

  test "it shows the live configuration rather than hardcoded numbers", %{conn: conn} do
    # A guide that can drift out of step with the system it documents is worse
    # than no guide, so these are read from config at render time.
    html = conn |> get(~p"/") |> html_response(200)

    config = Application.get_env(:job_runner, :jobs, [])
    assert html =~ to_string(Keyword.fetch!(config, :max_concurrency))
    assert html =~ to_string(Keyword.fetch!(config, :max_attempts))
    assert html =~ JobRunner.LLM.config()[:model]
  end

  test "it explains the behaviour that surprises people", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    # Turning the network off and seeing nothing fail is correct, and
    # counterintuitive enough to be worth saying before someone files it as a bug.
    assert html =~ "Turn off your wifi"
    assert html =~ "circuit breaker"
  end

  test "navigation to the dashboard is present on every page", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "Overview"
    assert html =~ "Dashboard"
  end
end
