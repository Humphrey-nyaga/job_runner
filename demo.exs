# Demo script — every claim in the README, demonstrated.
#
#   mix run demo.exs
#
# Uses the Mock adapter for the failure scenarios (deterministic, no network,
# no cost) and the real configured provider for the live section. Each section
# prints what it is proving.

alias JobRunner.Jobs
alias JobRunner.Jobs.{Breaker, Queue, Store}
alias JobRunner.LLM.{Error, Mock}

defmodule Demo do
  def section(title) do
    IO.puts("\n\n\e[1;36m━━━ #{title} ━━━\e[0m")
  end

  def note(text), do: IO.puts("\e[2m#{text}\e[0m")

  def drain(timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    stats = Jobs.stats()

    cond do
      stats.pending + stats.running == 0 -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> Process.sleep(100) && do_drain(deadline)
    end
  end

  def await(fun, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> Process.sleep(50) && do_await(fun, deadline)
    end
  end

  def show(id) do
    {:ok, job} = Jobs.fetch(id)

    IO.puts(
      "  #{String.pad_trailing(to_string(job.type), 10)} " <>
        "#{String.pad_trailing(to_string(job.status), 10)} " <>
        "attempts=#{job.attempts}/#{job.max_attempts}  #{inspect(job.result || job.error)}"
    )
  end
end

{:ok, _} = Mock.start_link()

# ---------------------------------------------------------------------------
Demo.section("1. Supervision tree")

Demo.note("The shape the whole design argument rests on (ADR-002).")

for {id, _pid, type, _} <- Supervisor.which_children(JobRunner.Jobs.Supervisor) |> Enum.reverse() do
  IO.puts("  Jobs.Supervisor (rest_for_one) -> #{inspect(id)} (#{type})")
end

for {id, _pid, type, _} <-
      Supervisor.which_children(JobRunner.Jobs.ExecutionSupervisor) |> Enum.reverse() do
  IO.puts("    ExecutionSupervisor (one_for_all) -> #{inspect(id)} (#{type})")
end

# ---------------------------------------------------------------------------
Demo.section("2. A real job, end to end")

Demo.note("Live call against #{JobRunner.LLM.config()[:base_url]}")

{:ok, echo} = Jobs.add_job(%{prompt: "Reply with exactly: ledger reconciled.", type: :echo})

{:ok, structured} =
  Jobs.add_job(%{
    prompt: "Q3 revenue rose 4% to KES 812M on mobile lending. Audit found no material issues.",
    type: :summarize
  })

Demo.drain()
Demo.show(echo)
Demo.show(structured)
Demo.note("The structured job returned a validated map, not raw text.")

# ---------------------------------------------------------------------------
Demo.section("3. Bounded concurrency")

Mock.script([{:sleep, 400, {:ok, "done"}}])
llm = Application.get_env(:job_runner, :llm)
Application.put_env(:job_runner, :llm, Keyword.put(llm, :adapter, Mock))

for n <- 1..12, do: Jobs.add_job("concurrent job #{n}")

samples =
  for _ <- 1..12,
      do:
        (
          Process.sleep(60)
          Queue.in_flight_count()
        )

IO.puts("  in-flight samples: #{inspect(samples)}")
IO.puts("  ceiling observed:  #{Enum.max(samples)} (max_concurrency = 4)")
Demo.note("An unbounded number of concurrent LLM calls is not a design decision.")
Demo.drain()

# ---------------------------------------------------------------------------
Demo.section("4. Retry with exponential backoff")

Mock.script([
  {:error, Error.timeout()},
  {:error, Error.http_status(503, "unavailable")},
  {:ok, "third time lucky"}
])

{:ok, flaky} = Jobs.add_job("fails twice then succeeds")
Demo.drain()

{:ok, job} = Jobs.fetch(flaky)
Demo.show(flaky)

backoffs = job.history |> Enum.reverse() |> Enum.map(& &1.backoff_ms) |> Enum.reject(&is_nil/1)
IO.puts("  backoff gaps: #{inspect(backoffs)} ms")
Demo.note("Jittered, and the slot was free the whole time — the Queue waits, not the worker.")

# ---------------------------------------------------------------------------
Demo.section("5. Permanent failures are not retried")

Mock.script([{:error, Error.http_status(400, "malformed prompt")}])
{:ok, permanent} = Jobs.add_job("this can never succeed")
Demo.drain()
Demo.show(permanent)
Demo.note("One attempt, not five. A 400 sends identical bytes and fails identically.")

# ---------------------------------------------------------------------------
Demo.section("6. Dead letter queue and replay")

Mock.script([{:error, Error.timeout()}])
{:ok, doomed} = Jobs.add_job("exhausts its budget")
Demo.await(fn -> match?({:ok, %{status: :failed}}, Jobs.fetch(doomed)) end, 30_000)

{:ok, dead} = Jobs.fetch(doomed)
IO.puts("  dead letters: #{length(Jobs.dead_letters())}")

IO.puts("  attempt history (newest first):")

for attempt <- dead.history do
  IO.puts(
    "    ##{attempt.attempt_no} #{attempt.outcome} " <>
      "backoff=#{attempt.backoff_ms || "-"}ms error=#{inspect(attempt.error && attempt.error.class)}"
  )
end

Mock.script([{:ok, "works now"}])
{:ok, _} = Jobs.requeue(doomed)
Demo.drain()
Demo.show(doomed)
Demo.note("Replay is manual on purpose: an automatic DLQ drain is an infinite retry storm.")

# ---------------------------------------------------------------------------
Demo.section("7. Crash isolation")

# Crash reports are the system working; they would otherwise drown the output.
previous_level = Logger.level()
Logger.configure(level: :critical)

queue_before = Process.whereis(Queue)
Mock.script([{:raise, "job exploded"}])
{:ok, crasher} = Jobs.add_job("raises an exception")

Demo.await(fn -> match?({:ok, %{attempts: n}} when n >= 1, Jobs.fetch(crasher)) end)
IO.puts("  Queue pid before: #{inspect(queue_before)}")
IO.puts("  Queue pid after:  #{inspect(Process.whereis(Queue))}")
Demo.note("A crashing job is an outcome, not an outage. async_nolink makes that structural.")
Demo.drain(40_000)
Logger.configure(level: previous_level)

# ---------------------------------------------------------------------------
Demo.section("8. Circuit breaker — an outage costs time, not jobs")

jobs_config = Application.get_env(:job_runner, :jobs)

Application.put_env(
  :job_runner,
  :jobs,
  jobs_config
  |> Keyword.put(:breaker_threshold, 3)
  |> Keyword.put(:breaker_cooldown_ms, 1_000)
  # Capped low so the demo does not sit through production-scale cooldowns.
  |> Keyword.put(:breaker_max_cooldown_ms, 2_000)
)

dlq_before = length(Jobs.dead_letters())
Mock.script([{:error, Error.transport(:econnrefused)}])
ids = for n <- 1..10, do: elem(Jobs.add_job("during the outage #{n}"), 1)

Demo.await(fn -> Breaker.open?(Jobs.breaker()) end)
Process.sleep(300)

untouched = ids |> Enum.map(&elem(Jobs.fetch(&1), 1)) |> Enum.count(&(&1.attempts == 0))
IO.puts("  breaker:            #{Jobs.breaker().state}")
IO.puts("  jobs never touched: #{untouched}/10 (budgets intact)")
IO.puts("  new dead letters:   #{length(Jobs.dead_letters()) - dlq_before}")
Demo.note("Without a breaker all 10 would burn 5 attempts each and drain into the DLQ.")

IO.puts("\n  ...endpoint recovers...")
Mock.script([{:ok, "recovered"}])

# Report what actually happened rather than asserting the happy path.
case Demo.await(fn -> Jobs.breaker().state == :closed end, 20_000) do
  :ok -> IO.puts("  breaker:          closed by a single half-open probe")
  :timeout -> IO.puts("  breaker:          #{Jobs.breaker().state} (still cooling down)")
end

Demo.drain(60_000)
IO.puts("  new dead letters: #{length(Jobs.dead_letters()) - dlq_before}")
recovered = Enum.count(ids, fn id -> match?({:ok, %{status: :completed}}, Jobs.fetch(id)) end)
IO.puts("  recovered:        #{recovered}/10")

# ---------------------------------------------------------------------------
Demo.section("9. Fault tolerance — kill the Queue mid-flight")

Mock.script([{:sleep, 1_500, {:ok, "survived the restart"}}])
ids = for n <- 1..4, do: elem(Jobs.add_job("in flight #{n}"), 1)

Demo.await(fn -> Queue.in_flight_count() == 4 end)
IO.puts("  in flight:        #{Queue.in_flight_count()}")
IO.puts("  Store pid:        #{inspect(Process.whereis(Store))}")

queue_before = Process.whereis(Queue)
Process.exit(queue_before, :kill)
IO.puts("  ...Process.exit(queue, :kill)...")

Demo.await(fn -> is_pid(Process.whereis(Queue)) and Process.whereis(Queue) != queue_before end)
IO.puts("  Queue pid:        #{inspect(queue_before)} -> #{inspect(Process.whereis(Queue))}")
IO.puts("  Store pid:        #{inspect(Process.whereis(Store))} (unchanged — rest_for_one)")

Mock.script([{:ok, "survived the restart"}])
Demo.drain(40_000)

stranded = Enum.count(ids, fn id -> match?({:ok, %{status: :running}}, Jobs.fetch(id)) end)
completed = Enum.count(ids, fn id -> match?({:ok, %{status: :completed}}, Jobs.fetch(id)) end)

IO.puts("  stranded :running: #{stranded}  (must be 0 — ADR-013 reconciliation)")
IO.puts("  completed:         #{completed}/4")

{:ok, sample} = Jobs.fetch(hd(ids))
IO.puts("  interrupted recorded: #{Enum.any?(sample.history, &(&1.outcome == :interrupted))}")
IO.puts("  budget spent:         #{sample.attempts} (interruption refunded)")

# ---------------------------------------------------------------------------
Demo.section("10. Provider swappability")

IO.puts("  behaviour:      JobRunner.LLM")

IO.puts("  implementations: #{inspect([JobRunner.LLM.OpenAICompatible, JobRunner.LLM.Mock])}")

Demo.note("Sections 3-9 ran against Mock; section 2 ran against a real HTTP endpoint.")
Demo.note("The engine never knew the difference — it is one config key.")

Application.put_env(:job_runner, :llm, llm)
Application.put_env(:job_runner, :jobs, jobs_config)

# ---------------------------------------------------------------------------
Demo.section("Final metrics")

Jobs.metrics()
|> Enum.sort()
|> Enum.each(fn {k, v} -> IO.puts("  #{String.pad_trailing(to_string(k), 16)} #{v}") end)

IO.puts("\n\e[1;32mDemo complete.\e[0m Dashboard: mix phx.server → http://localhost:4000/jobs\n")
