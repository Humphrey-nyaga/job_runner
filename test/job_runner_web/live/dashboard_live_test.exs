defmodule JobRunnerWeb.DashboardLiveTest do
  @moduledoc "Dashboard behaviour. The UI is thin; these check it is wired, not pretty."

  use JobRunnerWeb.ConnCase, async: false
  use JobRunner.JobsCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :capture_log

  describe "mount" do
    test "renders with an empty system", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/jobs")

      assert html =~ "Job Runner"
      assert html =~ "No jobs yet."
      assert html =~ "Circuit closed"
    end

    test "lists existing jobs", %{conn: conn} do
      {:ok, id} = Jobs.add_job("summarise the ledger")
      await_status(id, :completed)

      {:ok, _view, html} = live(conn, ~p"/jobs")
      assert html =~ "summarise the ledger"
    end
  end

  describe "submitting" do
    test "creates a job and shows it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs")

      html =
        view
        |> form("form", %{prompt: "from the browser", type: "echo", priority: "high"})
        |> render_submit()

      assert html =~ "from the browser"
      assert [%Job{prompt: "from the browser", priority: :high}] = Jobs.all()
    end

    test "admission errors are shown rather than swallowed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs")

      html =
        view
        |> form("form", %{prompt: "   ", type: "echo", priority: "normal"})
        |> render_submit()

      assert html =~ "Prompt cannot be blank"
      assert Jobs.all() == []
    end
  end

  describe "live updates" do
    test "a status change re-renders without a remount", %{conn: conn} do
      Mock.script([{:sleep, 200, {:ok, "eventually"}}])
      {:ok, view, _html} = live(conn, ~p"/jobs")

      {:ok, id} = Jobs.add_job("slow job")

      # Driven by the Store's PubSub broadcast, not by the poll interval.
      assert render(view) =~ "slow job"
      await_status(id, :completed, 3_000)
      assert render(view) =~ "eventually"
    end
  end

  describe "dead letter tab" do
    test "shows exhausted jobs and requeues them", %{conn: conn} do
      Mock.script([{:error, Error.http_status(400, "bad")}])
      {:ok, id} = Jobs.add_job("doomed")
      await_status(id, :failed, 5_000)

      {:ok, view, _html} = live(conn, ~p"/jobs")

      html = view |> element("button", "Dead letters") |> render_click()
      assert html =~ "doomed"
      assert html =~ "Requeue"

      Mock.script([{:ok, "fixed"}])
      view |> element("button", "Requeue") |> render_click()

      assert %Job{status: :completed} = await_status(id, :completed, 5_000)
      assert Jobs.dead_letters() == []
    end
  end

  describe "status filters" do
    setup do
      Mock.script([{:ok, "finished"}])
      {:ok, done} = Jobs.add_job("a completed job")
      await_status(done, :completed, 5_000)

      Mock.script([{:error, Error.http_status(400, "bad")}])
      {:ok, failed} = Jobs.add_job("a failed job")
      await_status(failed, :failed, 5_000)

      {:ok, done: done, failed: failed}
    end

    test "filtering to completed hides failures, and vice versa", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs")

      completed = view |> element("button", "Completed") |> render_click()
      assert completed =~ "a completed job"
      refute completed =~ "a failed job"

      failed = view |> element("button", "Failed") |> render_click()
      assert failed =~ "a failed job"
      refute failed =~ "a completed job"
    end

    test "an empty filter explains itself rather than looking broken", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs")

      assert view |> element("button", "Running") |> render_click() =~ "Nothing running right now"
    end

    test "a deep queue reports the total, not a silent truncation", %{conn: conn} do
      # Sorting newest-first and cutting at N hides the system's state: seed
      # enough jobs and every visible row is pending, so a healthy queue looks
      # stuck. The total has to be reported.
      Mock.script([{:sleep, 5_000, {:ok, "slow"}}])
      for n <- 1..120, do: Jobs.add_job("bulk #{n}")

      {:ok, view, _html} = live(conn, ~p"/jobs")
      html = view |> element("button", "Pending") |> render_click()

      assert html =~ ~r/Showing the \d+ most recent of \d+ matching jobs/
    end
  end

  describe "job detail" do
    test "shows the full prompt, result and attempt history", %{conn: conn} do
      Mock.script([
        {:error, Error.timeout()},
        {:ok, ~s({"summary": "A full and complete summary.", "category": "finance"})}
      ])

      {:ok, id} = Jobs.add_job(%{prompt: "a very specific prompt", type: :summarize})
      await_status(id, :completed, 8_000)

      {:ok, view, _html} = live(conn, ~p"/jobs")
      html = view |> element("tr[phx-value-id='#{id}']") |> render_click()

      assert html =~ "Job detail"
      assert html =~ "a very specific prompt"
      assert html =~ "A full and complete summary."
      # Both attempts, including the one that failed and its backoff.
      assert html =~ "Attempt history (2)"
      assert html =~ "interrupted" or html =~ "error"
    end

    test "the panel follows the job instead of freezing on the click snapshot",
         %{conn: conn} do
      Mock.script([{:sleep, 300, {:ok, "eventually done"}}])
      {:ok, id} = Jobs.add_job("slow job")

      {:ok, view, _html} = live(conn, ~p"/jobs")
      assert view |> element("tr[phx-value-id='#{id}']") |> render_click() =~ "Job detail"

      await_status(id, :completed, 5_000)
      assert render(view) =~ "eventually done"
    end

    test "closes", %{conn: conn} do
      {:ok, id} = Jobs.add_job("x")
      await_status(id, :completed)

      {:ok, view, _html} = live(conn, ~p"/jobs")
      view |> element("tr[phx-value-id='#{id}']") |> render_click()

      refute view |> element("button", "Close") |> render_click() =~ "Job detail"
    end
  end

  describe "manual retry" do
    setup do
      Mock.script([{:error, Error.http_status(400, "bad")}])
      {:ok, id} = Jobs.add_job("needs a retry")
      await_status(id, :failed, 5_000)
      {:ok, id: id}
    end

    test "a failed job can be retried from the main table", %{conn: conn, id: id} do
      {:ok, view, _html} = live(conn, ~p"/jobs")

      Mock.script([{:ok, "fixed"}])
      view |> element("tr[phx-value-id='#{id}'] button", "Retry") |> render_click()

      assert %Job{status: :completed, result: "fixed"} = await_status(id, :completed, 5_000)
      assert Jobs.dead_letters() == []
    end

    test "and from the detail panel", %{conn: conn, id: id} do
      {:ok, view, _html} = live(conn, ~p"/jobs")
      view |> element("tr[phx-value-id='#{id}']") |> render_click()

      Mock.script([{:ok, "fixed"}])
      view |> element("button", "Retry with a fresh budget") |> render_click()

      assert %Job{status: :completed} = await_status(id, :completed, 5_000)
    end

    test "retry restores a full budget rather than resuming a spent one", %{conn: conn, id: id} do
      {:ok, view, _html} = live(conn, ~p"/jobs")
      Mock.script([{:ok, "fixed"}])
      view |> element("tr[phx-value-id='#{id}'] button", "Retry") |> render_click()

      job = await_status(id, :completed, 5_000)
      assert job.attempts == 1
    end

    test "requeue all drains the dead letter queue", %{conn: conn} do
      Mock.script([{:error, Error.http_status(400, "bad")}])
      extra = for n <- 1..3, do: elem(Jobs.add_job("also failed #{n}"), 1)
      for id <- extra, do: await_status(id, :failed, 5_000)

      {:ok, view, _html} = live(conn, ~p"/jobs")
      view |> element("button", "Dead letters") |> render_click()

      Mock.script([{:ok, "fixed"}])
      view |> element("button", ~r/Requeue all/) |> render_click()

      for id <- extra, do: assert(%Job{status: :completed} = await_status(id, :completed, 5_000))
      assert Jobs.dead_letters() == []
    end
  end

  describe "pending breakdown" do
    @tag jobs_config: [backoff_base_ms: 30_000]
    test "jobs awaiting a backoff are shown, not hidden behind an empty queue depth",
         %{conn: conn} do
      # Regression: "Pending: 6, queue depth: 0" is a correct reading of a retry
      # storm and looks exactly like a bug, because a job on a backoff timer is
      # deliberately not in any FIFO.
      Mock.script([{:error, Error.timeout()}])
      ids = for n <- 1..4, do: elem(Jobs.add_job("failing #{n}"), 1)

      eventually(fn -> Jobs.stats().scheduled == length(ids) end, 5_000)

      {:ok, _view, html} = live(conn, ~p"/jobs")

      # A job on a backoff timer is deliberately not in any FIFO, so reporting
      # only queue depth would show zero while several jobs are pending.
      assert html =~ "awaiting retry"
      assert Jobs.stats().scheduled == length(ids)
    end

    test "the breakdown always reconciles with the pending total" do
      Mock.script([{:sleep, 2_000, {:ok, "slow"}}])
      for n <- 1..8, do: Jobs.add_job("job #{n}")

      eventually(fn -> Jobs.stats().running > 0 end)
      stats = Jobs.stats()

      assert stats.runnable + stats.scheduled == stats.pending
      assert stats.queue_depth == stats.runnable
    end
  end

  describe "breaker visibility" do
    @tag jobs_config: [breaker_threshold: 2, breaker_cooldown_ms: 60_000]
    test "an idle system explains itself", %{conn: conn} do
      Mock.script([{:error, Error.transport(:econnrefused)}])
      for n <- 1..6, do: Jobs.add_job("job #{n}")
      eventually(fn -> Jobs.breaker().state == :open end, 5_000)

      {:ok, _view, html} = live(conn, ~p"/jobs")

      # "Why is nothing running?" must have a visible answer rather than
      # looking like a hang.
      assert html =~ "Circuit open"
      assert html =~ "dispatch suppressed"
    end
  end
end
