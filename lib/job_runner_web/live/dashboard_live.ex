defmodule JobRunnerWeb.DashboardLive do
  @moduledoc """
  Live view of the job system.

  Two data paths, deliberately different:

    * **Job rows** arrive by PubSub. The Store broadcasts every write, so the
      table updates on the transition itself rather than on a poll — no interval,
      no staleness window.

    * **Counters and queue depths** are read on a slow tick. They are aggregates
      with no natural event to hang off, and recomputing them on every job
      transition would do far more work than the display justifies.

  Reads go straight to ETS, so an open dashboard never queues behind
  dispatch. Rendering this page cannot slow the engine down, which is the
  property that makes it safe to leave open during a demo.

  ## Why the table is filtered rather than simply truncated

  Sorting newest-first and cutting at N is the obvious approach and it hides the
  system's state: seed 200 jobs and every visible row is pending, because the
  completed ones fall below the cut. A healthy queue then looks stuck.

  """

  use JobRunnerWeb, :live_view

  alias JobRunner.Jobs
  alias JobRunner.Jobs.{Job, JobType}

  @tick 1_000
  @page_size 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Jobs.subscribe()
      :timer.send_interval(@tick, :tick)
    end

    {:ok,
     socket
     |> assign(filter: :all, selected_id: nil, prompt: "", flash_error: nil)
     |> load()}
  end

  @impl true
  def handle_info({:job_updated, _job}, socket), do: {:noreply, load(socket)}
  def handle_info({:breaker_changed, _breaker}, socket), do: {:noreply, load(socket)}
  def handle_info(:tick, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event(
        "submit",
        %{"prompt" => prompt, "type" => type, "priority" => priority},
        socket
      ) do
    attrs = %{
      prompt: prompt,
      type: String.to_existing_atom(type),
      priority: String.to_existing_atom(priority)
    }

    case Jobs.add_job(attrs) do
      {:ok, _id} ->
        {:noreply, socket |> assign(prompt: "", flash_error: nil) |> load()}

      {:error, reason} ->
        {:noreply, assign(socket, flash_error: humanise(reason))}
    end
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, socket |> assign(filter: String.to_existing_atom(filter)) |> load()}
  end

  def handle_event("select", %{"id" => id}, socket) do
    # assign_selected/1 resolves the id into the job. Assigning only the id
    # leaves `@selected` at its previous value, so the panel never opens.
    {:noreply, socket |> assign(selected_id: id) |> assign_selected()}
  end

  def handle_event("close", _params, socket),
    do: {:noreply, assign(socket, selected_id: nil, selected: nil)}

  def handle_event("requeue", %{"id" => id}, socket) do
    case Jobs.requeue(id) do
      {:ok, _id} -> {:noreply, socket |> assign(flash_error: nil) |> load()}
      {:error, reason} -> {:noreply, assign(socket, flash_error: humanise(reason))}
    end
  end

  def handle_event("requeue_all", _params, socket) do
    for job <- Jobs.dead_letters(), do: Jobs.requeue(job.id)
    {:noreply, load(socket)}
  end

  def handle_event("seed", %{"n" => n}, socket) do
    for i <- 1..String.to_integer(n) do
      Jobs.add_job(%{
        prompt: "Demo job #{i}: summarise this quarter's ledger movement.",
        type: :echo
      })
    end

    {:noreply, load(socket)}
  end

  defp load(socket) do
    all = Jobs.all()
    filtered = filter_jobs(all, socket.assigns.filter)

    socket
    |> assign(
      counts: %{
        all: length(all),
        pending: count(all, :pending),
        running: count(all, :running),
        completed: count(all, :completed),
        failed: count(all, :failed)
      },
      total_matching: length(filtered),
      jobs: Enum.take(filtered, @page_size),
      dead_letters: Jobs.dead_letters(),
      stats: Jobs.stats(),
      metrics: Jobs.metrics(),
      breaker: Jobs.breaker()
    )
    |> assign_selected()
  end

  # Re-read the selected job from the Store on every render so an open detail
  # panel follows the job through its lifecycle instead of freezing on the
  # snapshot that was current when it was clicked.
  defp assign_selected(socket) do
    case socket.assigns.selected_id do
      nil ->
        assign(socket, selected: nil)

      id ->
        case Jobs.fetch(id) do
          {:ok, job} -> assign(socket, selected: job)
          {:error, :not_found} -> assign(socket, selected: nil, selected_id: nil)
        end
    end
  end

  defp filter_jobs(jobs, :all), do: jobs
  defp filter_jobs(jobs, :dlq), do: Enum.filter(jobs, &(&1.status == :failed))
  defp filter_jobs(jobs, status), do: Enum.filter(jobs, &(&1.status == status))

  defp count(jobs, status), do: Enum.count(jobs, &(&1.status == status))

  defp humanise(:invalid_prompt), do: "Prompt cannot be blank."
  defp humanise(:prompt_too_large), do: "Prompt is too large."
  defp humanise(:queue_full), do: "Queue is full — admission backpressure is active."
  defp humanise(:unknown_type), do: "Unknown job type."
  defp humanise(:not_dead_lettered), do: "Only failed jobs can be requeued."
  defp humanise(other), do: to_string(other)

  # --- Rendering -------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-7xl space-y-6 p-4">
        <header class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Job Runner</h1>
            <p class="text-sm opacity-70">Supervised, retrying, rate-limited LLM job queue</p>
          </div>
          <.breaker_badge breaker={@breaker} />
        </header>

        <section class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
          <.stat label="Pending" value={@counts.pending} />
          <.stat label="Running" value={@counts.running} accent="text-blue-500" />
          <.stat label="Completed" value={@counts.completed} accent="text-emerald-500" />
          <.stat label="Failed" value={@counts.failed} accent="text-rose-500" />
          <.stat label="Retried" value={@metrics.retried} accent="text-amber-500" />
          <.stat label="In flight" value={@stats.in_flight} sub={"limit #{@stats.in_flight_limit}"} />
        </section>

        <section class="grid gap-4 lg:grid-cols-3">
          <div class="lg:col-span-2">
            <.submit_form prompt={@prompt} error={@flash_error} />
          </div>
          <.side_panel stats={@stats} metrics={@metrics} />
        </section>

        <nav class="flex flex-wrap gap-1 border-b border-base-300">
          <.filter_tab filter={:all} active={@filter} label="All" count={@counts.all} />
          <.filter_tab filter={:pending} active={@filter} label="Pending" count={@counts.pending} />
          <.filter_tab filter={:running} active={@filter} label="Running" count={@counts.running} />
          <.filter_tab
            filter={:completed}
            active={@filter}
            label="Completed"
            count={@counts.completed}
          />
          <.filter_tab filter={:failed} active={@filter} label="Failed" count={@counts.failed} />
          <.filter_tab
            filter={:dlq}
            active={@filter}
            label="Dead letters"
            count={length(@dead_letters)}
          />
        </nav>

        <div :if={@filter == :dlq and @dead_letters != []} class="flex justify-end">
          <button
            phx-click="requeue_all"
            data-confirm="Requeue every dead-lettered job?"
            class="rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-sm text-amber-600 hover:bg-amber-500/20"
          >
            Requeue all {length(@dead_letters)}
          </button>
        </div>

        <.jobs_table jobs={@jobs} showing={length(@jobs)} total={@total_matching} filter={@filter} />

        <.detail_panel :if={@selected} job={@selected} />
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :accent, :string, default: ""
  attr :sub, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 p-4">
      <div class="text-xs uppercase tracking-wide opacity-60">{@label}</div>
      <div class={["mt-1 text-2xl font-semibold tabular-nums", @accent]}>{@value}</div>
      <div :if={@sub} class="text-xs opacity-50">{@sub}</div>
    </div>
    """
  end

  attr :breaker, :map, required: true

  defp breaker_badge(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-2 rounded-full px-4 py-2 text-sm font-medium",
      @breaker.state == :closed && "bg-emerald-500/10 text-emerald-600",
      @breaker.state == :open && "bg-rose-500/10 text-rose-600",
      @breaker.state == :half_open && "bg-amber-500/10 text-amber-600"
    ]}>
      <span class={[
        "size-2 rounded-full",
        @breaker.state == :closed && "bg-emerald-500",
        @breaker.state == :open && "bg-rose-500 animate-pulse",
        @breaker.state == :half_open && "bg-amber-500 animate-pulse"
      ]} /> Circuit {@breaker.state}
      <span :if={@breaker.state == :closed and @breaker.failures > 0} class="opacity-70">
        ({@breaker.failures} consecutive)
      </span>
      <span :if={@breaker.state != :closed} class="opacity-70">
        — dispatch suppressed
      </span>
    </div>
    """
  end

  attr :prompt, :string, required: true
  attr :error, :string, default: nil

  defp submit_form(assigns) do
    assigns = assign(assigns, types: JobType.names())

    ~H"""
    <form phx-submit="submit" class="rounded-xl border border-base-300 bg-base-100 p-4 space-y-3">
      <textarea
        name="prompt"
        rows="3"
        placeholder="Prompt to send to the model…"
        class="w-full rounded-lg border border-base-300 bg-base-200 p-3 text-sm"
      >{@prompt}</textarea>

      <div class="flex flex-wrap items-center gap-3">
        <select name="type" class="rounded-lg border border-base-300 bg-base-200 px-3 py-2 text-sm">
          <option :for={type <- @types} value={type}>{type}</option>
        </select>

        <select
          name="priority"
          class="rounded-lg border border-base-300 bg-base-200 px-3 py-2 text-sm"
        >
          <option :for={p <- [:normal, :high, :low]} value={p}>{p} priority</option>
        </select>

        <button class="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500">
          Submit job
        </button>

        <button
          type="button"
          phx-click="seed"
          phx-value-n="12"
          class="rounded-lg border border-base-300 px-4 py-2 text-sm hover:bg-base-200"
        >
          Seed 12 jobs
        </button>
      </div>

      <p :if={@error} class="text-sm text-rose-500">{@error}</p>
    </form>
    """
  end

  attr :stats, :map, required: true
  attr :metrics, :map, required: true

  defp side_panel(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 p-4 text-sm">
      <div class="mb-2 text-xs uppercase tracking-wide opacity-60">
        Pending breakdown
      </div>
      <dl class="space-y-1">
        <div class="flex justify-between">
          <dt class="opacity-70">Runnable now</dt>
          <dd class="tabular-nums">{@stats.runnable}</dd>
        </div>
        <div class="flex justify-between">
          <dt class="opacity-70" title="Waiting out a retry backoff, not holding a slot">
            Awaiting retry
          </dt>
          <dd class="tabular-nums text-amber-600">{@stats.scheduled}</dd>
        </div>
        <div class="flex justify-between border-t border-base-300 pt-1 font-medium">
          <dt>Pending total</dt>
          <dd class="tabular-nums">{@stats.pending}</dd>
        </div>
      </dl>
      <p :if={@stats.scheduled > 0} class="mt-1 text-xs opacity-50">
        Jobs awaiting a backoff are not in a queue — they are on a timer, so they
        hold no concurrency slot.
      </p>

      <div class="mt-4 mb-2 text-xs uppercase tracking-wide opacity-60">
        Queue depth by priority
      </div>
      <dl class="space-y-1">
        <div :for={p <- [:high, :normal, :low]} class="flex justify-between">
          <dt class="capitalize opacity-70">{p}</dt>
          <dd class="tabular-nums">{@stats.queued[p]}</dd>
        </div>
        <div class="flex justify-between border-t border-base-300 pt-1 font-medium">
          <dt>Queued</dt>
          <dd class="tabular-nums">{@stats.queue_depth}</dd>
        </div>
      </dl>

      <div class="mt-4 mb-2 text-xs uppercase tracking-wide opacity-60">Lifetime</div>
      <dl class="space-y-1">
        <div
          :for={
            {label, value} <- [
              {"Processed", @metrics.processed},
              {"Success rate", format_rate(@metrics.success_rate)},
              {"Retried", @metrics.retried},
              {"Crashed", @metrics.crashed},
              {"Timed out", @metrics.timed_out},
              {"Breaker trips", @metrics.breaker_trips}
            ]
          }
          class="flex justify-between"
        >
          <dt class="opacity-70">{label}</dt>
          <dd class="tabular-nums">{value}</dd>
        </div>
      </dl>
    </div>
    """
  end

  attr :filter, :atom, required: true
  attr :active, :atom, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true

  defp filter_tab(assigns) do
    ~H"""
    <button
      phx-click="filter"
      phx-value-filter={@filter}
      class={[
        "flex items-center gap-2 px-4 py-2 text-sm font-medium",
        @filter == @active && "border-b-2 border-blue-500 text-blue-500",
        @filter != @active && "opacity-60 hover:opacity-100"
      ]}
    >
      {@label}
      <span class="rounded-full bg-base-300 px-2 text-xs tabular-nums">{@count}</span>
    </button>
    """
  end

  attr :jobs, :list, required: true
  attr :showing, :integer, required: true
  attr :total, :integer, required: true
  attr :filter, :atom, required: true

  defp jobs_table(assigns) do
    ~H"""
    <div class="space-y-2">
      <p :if={@total > @showing} class="text-xs opacity-60">
        Showing the {@showing} most recent of {@total} matching jobs.
      </p>

      <div class="overflow-x-auto rounded-xl border border-base-300">
        <table class="w-full text-sm">
          <thead class="bg-base-200 text-left text-xs uppercase tracking-wide opacity-70">
            <tr>
              <th class="p-3">Prompt</th>
              <th class="p-3">Type</th>
              <th class="p-3">Priority</th>
              <th class="p-3">Status</th>
              <th class="p-3">Attempts</th>
              <th class="p-3">Result</th>
              <th class="p-3"></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={job <- @jobs}
              class="cursor-pointer border-t border-base-300 hover:bg-base-200"
              phx-click="select"
              phx-value-id={job.id}
            >
              <td class="p-3 max-w-xs truncate" title={job.prompt}>{job.prompt}</td>
              <td class="p-3 opacity-70">{job.type}</td>
              <td class="p-3 opacity-70">{job.priority}</td>
              <td class="p-3"><.status_badge job={job} /></td>
              <td class="p-3 tabular-nums">{job.attempts}/{job.max_attempts}</td>
              <td class="p-3 max-w-sm truncate opacity-80">{summarise_result(job)}</td>
              <td class="p-3 whitespace-nowrap text-right">
                <button
                  :if={job.status == :failed}
                  phx-click="requeue"
                  phx-value-id={job.id}
                  class="rounded-lg border border-base-300 px-3 py-1 text-xs hover:bg-base-300"
                >
                  Retry
                </button>
                <span class="ml-2 text-xs opacity-40">details →</span>
              </td>
            </tr>
            <tr :if={@jobs == []}>
              <td colspan="7" class="p-8 text-center opacity-50">{empty_message(@filter)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :job, :map, required: true

  defp detail_panel(assigns) do
    ~H"""
    <!--
      The backdrop deliberately has NO phx-click. The panel is a CHILD of it, so
      a click handler here fires for every click inside the panel too — the event
      bubbles — which closed the dialog on any click, and even on selecting text.

      phx-click-away on the panel already covers the backdrop: it fires for any
      click outside the panel, which is exactly the intended behaviour and
      nothing more.
    -->
    <div
      class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/50 p-4"
      phx-window-keydown="close"
      phx-key="Escape"
    >
      <div
        class="my-8 w-full max-w-3xl space-y-5 rounded-xl border border-base-300 bg-base-100 p-6 shadow-xl"
        phx-click-away="close"
      >
        <div class="flex items-start justify-between gap-4">
          <div>
            <h2 class="text-lg font-semibold">Job detail</h2>
            <p class="font-mono text-xs opacity-50">{@job.id}</p>
          </div>
          <div class="flex items-center gap-2">
            <button
              :if={@job.status == :failed}
              phx-click="requeue"
              phx-value-id={@job.id}
              class="rounded-lg border border-amber-500/40 bg-amber-500/10 px-3 py-1 text-sm text-amber-600 hover:bg-amber-500/20"
            >
              Retry with a fresh budget
            </button>
            <button phx-click="close" class="rounded-lg border border-base-300 px-3 py-1 text-sm">
              Close
            </button>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
          <.field label="Status"><.status_badge job={@job} /></.field>
          <.field label="Type">{@job.type}</.field>
          <.field label="Priority">{@job.priority}</.field>
          <.field label="Attempts">{@job.attempts} / {@job.max_attempts}</.field>
        </div>

        <div class="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
          <.field label="Submitted">{format_time(@job.inserted_at)}</.field>
          <.field label="Started">{format_time(@job.started_at)}</.field>
          <.field label="Finished">{format_time(@job.finished_at)}</.field>
          <.field label="Duration">{format_duration(@job)}</.field>
        </div>

        <div>
          <div class="mb-1 text-xs uppercase tracking-wide opacity-60">Prompt</div>
          <pre class="max-h-40 overflow-auto whitespace-pre-wrap rounded-lg bg-base-200 p-3 text-sm">{@job.prompt}</pre>
        </div>

        <div :if={@job.result}>
          <div class="mb-1 text-xs uppercase tracking-wide opacity-60">Result</div>
          <pre class="max-h-80 overflow-auto whitespace-pre-wrap rounded-lg bg-emerald-500/5 p-3 text-sm">{format_result(@job.result)}</pre>
        </div>

        <div :if={@job.error}>
          <div class="mb-1 text-xs uppercase tracking-wide opacity-60">Last error</div>
          <pre class="overflow-auto whitespace-pre-wrap rounded-lg bg-rose-500/5 p-3 text-sm text-rose-600">{format_error(@job.error)}</pre>
        </div>

        <div>
          <div class="mb-1 text-xs uppercase tracking-wide opacity-60">
            Attempt history ({length(@job.history)})
          </div>
          <div class="overflow-x-auto rounded-lg border border-base-300">
            <table class="w-full text-xs">
              <thead class="bg-base-200 text-left uppercase tracking-wide opacity-70">
                <tr>
                  <th class="p-2">#</th>
                  <th class="p-2">Outcome</th>
                  <th class="p-2">Started</th>
                  <th class="p-2">Took</th>
                  <th class="p-2">Backoff</th>
                  <th class="p-2">Error</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={attempt <- Enum.reverse(@job.history)} class="border-t border-base-300">
                  <td class="p-2 tabular-nums">{attempt.attempt_no}</td>
                  <td class={[
                    "p-2 font-medium",
                    attempt.outcome == :ok && "text-emerald-600",
                    attempt.outcome == :error && "text-rose-600",
                    attempt.outcome == :interrupted && "text-amber-600"
                  ]}>
                    {attempt.outcome || "running"}
                  </td>
                  <td class="p-2 opacity-70">{format_time(attempt.started_at)}</td>
                  <td class="p-2 tabular-nums opacity-70">{attempt_duration(attempt)}</td>
                  <td class="p-2 tabular-nums opacity-70">
                    {if attempt.backoff_ms, do: "#{attempt.backoff_ms}ms", else: "—"}
                  </td>
                  <td class="p-2 max-w-xs truncate opacity-70">{format_error(attempt.error)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <div>
      <div class="text-xs uppercase tracking-wide opacity-60">{@label}</div>
      <div class="mt-0.5">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :job, :map, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "rounded-full px-2 py-1 text-xs font-medium",
      @job.status == :pending && "bg-base-300",
      @job.status == :running && "bg-blue-500/15 text-blue-600",
      @job.status == :completed && "bg-emerald-500/15 text-emerald-600",
      @job.status == :failed && "bg-rose-500/15 text-rose-600"
    ]}>
      {if Job.retrying?(@job), do: "retrying", else: @job.status}
    </span>
    """
  end

  defp empty_message(:failed), do: "No failures. Nothing has exhausted its retries."
  defp empty_message(:dlq), do: "No dead letters. Nothing has exhausted its retries."
  defp empty_message(:running), do: "Nothing running right now."
  defp empty_message(:pending), do: "Queue is empty."
  defp empty_message(_), do: "No jobs yet."

  defp summarise_result(%Job{status: :completed, result: %{summary: summary, category: category}}),
    do: "[#{category}] #{summary}"

  defp summarise_result(%Job{status: :completed, result: result}) when is_binary(result),
    do: result

  defp summarise_result(%Job{status: :failed, error: error}), do: format_error(error)
  defp summarise_result(%Job{}), do: ""

  # Structured results are pretty-printed; raw text is shown as-is rather than
  # inspected, so a multi-line completion reads as prose instead of "\n" escapes.
  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: inspect(result, pretty: true, width: 80)

  defp format_error(%{class: class, message: message, preview: preview}) do
    [to_string(class), message, preview] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  defp format_error({kind, detail}) when is_atom(kind), do: "#{kind}: #{inspect(detail)}"
  defp format_error(nil), do: ""
  defp format_error(other), do: inspect(other)

  defp format_rate(nil), do: "—"
  defp format_rate(rate), do: "#{rate}%"

  defp format_time(nil), do: "—"

  defp format_time(%DateTime{} = at),
    do: at |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_string()

  defp format_duration(%Job{started_at: nil}), do: "—"
  defp format_duration(%Job{finished_at: nil}), do: "—"

  defp format_duration(%Job{started_at: started, finished_at: finished}),
    do: "#{DateTime.diff(finished, started, :millisecond)}ms"

  defp attempt_duration(%{started_at: started, finished_at: finished})
       when not is_nil(started) and not is_nil(finished),
       do: "#{DateTime.diff(finished, started, :millisecond)}ms"

  defp attempt_duration(_), do: "—"
end
