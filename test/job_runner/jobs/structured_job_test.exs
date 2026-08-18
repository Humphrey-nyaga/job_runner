defmodule JobRunner.Jobs.StructuredJobTest do
  @moduledoc """
  Structured JSON jobs inside the running engine.

  The point of these: a malformed model response re-enters the *same* retry and
  backoff machinery as an HTTP 503, without the Queue knowing anything about
  JSON. That uniformity is the design working.
  """

  use JobRunner.JobsCase, async: false

  @moduletag :capture_log

  @valid ~s({"summary": "Revenue rose four percent.", "category": "finance"})

  describe "the happy path" do
    test "a structured job completes with a parsed map, not raw text" do
      Mock.script([{:ok, @valid}])

      {:ok, id} = Jobs.add_job(%{prompt: "Q3 revenue was up 4%", type: :summarize})
      job = await_status(id, :completed, 5_000)

      assert job.result == %{summary: "Revenue rose four percent.", category: :finance}
      assert job.attempts == 1
    end

    test "the job type's JSON-mode option reaches the adapter" do
      Mock.script([{:ok, @valid}])

      {:ok, id} = Jobs.add_job(%{prompt: "x", type: :summarize})
      await_status(id, :completed, 5_000)

      assert [{_messages, opts}] = Mock.calls()
      assert opts[:response_format] == %{type: "json_object"}
    end

    test "an echo job is unaffected by any of this" do
      Mock.script([{:ok, "plain text answer"}])

      {:ok, id} = Jobs.add_job(%{prompt: "x", type: :echo})
      job = await_status(id, :completed, 5_000)

      assert job.result == "plain text answer"
    end
  end

  describe "malformed output is a retryable failure" do
    test "garbage then valid JSON — the job recovers" do
      Mock.script([
        {:ok, "I'm sorry, I can't do that."},
        {:ok, ~s({"summary": "ok"})},
        {:ok, @valid}
      ])

      {:ok, id} = Jobs.add_job(%{prompt: "x", type: :summarize})
      job = await_status(id, :completed, 8_000)

      # Three attempts: not JSON, then wrong shape, then good. Resampling a
      # non-deterministic generator is exactly the right response.
      assert job.attempts == 3
      assert job.result.category == :finance
    end

    test "persistently malformed output exhausts the budget and dead-letters" do
      Mock.script([{:ok, "never valid json"}])

      {:ok, id} = Jobs.add_job(%{prompt: "x", type: :summarize})
      job = await_status(id, :failed, 20_000)

      assert job.attempts == job.max_attempts
      assert [%Job{id: ^id}] = Jobs.dead_letters()
    end

    test "the failure is diagnosable from the attempt history" do
      Mock.script([{:ok, "not json at all"}])

      {:ok, id} = Jobs.add_job(%{prompt: "x", type: :summarize})
      job = await_status(id, :failed, 20_000)

      # A dead letter that only says "it failed" is a log line. This says what
      # the model actually returned.
      assert {:invalid_json, preview} = job.error
      assert preview =~ "not json"
      assert Enum.all?(job.history, &(&1.outcome == :error))
    end

    test "malformed output never trips the circuit breaker" do
      Mock.script([{:ok, "not json"}])

      {:ok, id} = Jobs.add_job(%{prompt: "x", type: :summarize})
      await_status(id, :failed, 20_000)

      # The endpoint answered every time, promptly and with a 200. It is
      # healthy — only the generations were unusable. Tripping here would take
      # the system offline because one model is having a bad day.
      assert Jobs.breaker().state == :closed
    end
  end

  describe "backoff applies to parse failures too" do
    test "retries are spaced, not hammered" do
      Mock.script([{:ok, "not json"}, {:ok, "not json"}, {:ok, @valid}])

      {:ok, id} = Jobs.add_job(%{prompt: "x", type: :summarize})
      job = await_status(id, :completed, 8_000)

      backoffs =
        job.history |> Enum.map(& &1.backoff_ms) |> Enum.reject(&is_nil/1) |> Enum.reverse()

      # The Queue does not know these were JSON failures. They flow through the
      # identical path as a 503.
      assert length(backoffs) == 2
      assert Enum.all?(backoffs, &(&1 > 0))
      assert Enum.at(backoffs, 1) > Enum.at(backoffs, 0)
    end
  end
end
