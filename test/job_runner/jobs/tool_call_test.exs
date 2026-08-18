defmodule JobRunner.Jobs.ToolCallTest do
  @moduledoc """
  The tool-call round: a model asks for one local function, gets the result, and
  answers with it.

  The interesting assertions are the *limits* — the whitelist, the one-round cap,
  and what happens when a tool or a second call fails.
  """

  use JobRunner.JobsCase, async: false

  @moduletag :capture_log

  alias JobRunner.Jobs.Tools

  describe "Tools whitelist" do
    test "runs a permitted tool" do
      assert {:ok, time} = Tools.invoke("get_time")
      assert time =~ ~r/^\d{4}-\d{2}-\d{2}T/
    end

    test "job_stats reports live system state" do
      assert {:ok, stats} = Tools.invoke("job_stats")
      assert stats =~ "pending="
      assert stats =~ "completed="
    end

    test "an unknown name is refused rather than resolved" do
      assert {:error, :unknown_tool} = Tools.invoke("nonexistent")
    end

    test "a real function elsewhere in the system is still refused" do
      # The whole security property: the model supplies a *name*, and names are
      # untrusted. Nothing here turns a name into a function via
      # String.to_existing_atom/1 + apply/3, which would be arbitrary code
      # execution chosen by model output.
      assert {:error, :unknown_tool} = Tools.invoke("System.halt")
      assert {:error, :unknown_tool} = Tools.invoke("Elixir.File.rm_rf")
      assert {:error, :unknown_tool} = Tools.invoke("get_time/0")
    end

    test "non-string input is refused" do
      assert {:error, :unknown_tool} = Tools.invoke(:get_time)
      assert {:error, :unknown_tool} = Tools.invoke(nil)
    end

    test "describe/0 lists every tool for the prompt" do
      description = Tools.describe()
      for name <- Tools.names(), do: assert(description =~ name)
    end
  end

  describe "the happy path: one tool round" do
    test "the model asks for a tool, gets the result, and answers with it" do
      Mock.script([
        {:ok, ~s({"tool": "get_time"})},
        {:ok, ~s({"answer": "The current time was supplied by the tool."})}
      ])

      {:ok, id} = Jobs.add_job(%{prompt: "What time is it?", type: :assisted})
      job = await_status(id, :completed, 5_000)

      assert job.result == "The current time was supplied by the tool."
      # Two HTTP calls, but a single attempt: the round trip is internal to the
      # attempt, so the retry budget still means what it says.
      assert Mock.call_count() == 2
      assert job.attempts == 1
    end

    test "the tool result is actually fed back to the model" do
      Mock.script([
        {:ok, ~s({"tool": "get_time"})},
        {:ok, ~s({"answer": "done"})}
      ])

      {:ok, id} = Jobs.add_job(%{prompt: "What time is it?", type: :assisted})
      await_status(id, :completed, 5_000)

      [_first, {follow_up_messages, _opts}] = Mock.calls()
      content = follow_up_messages |> Enum.map_join("\n", & &1.content)

      assert content =~ "Tool `get_time` returned"
      # An ISO timestamp from the real function, not a placeholder.
      assert content =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    end

    test "the follow-up replays the model's own request as an assistant turn" do
      Mock.script([{:ok, ~s({"tool": "job_stats"})}, {:ok, ~s({"answer": "ok"})}])

      {:ok, id} = Jobs.add_job(%{prompt: "How busy are you?", type: :assisted})
      await_status(id, :completed, 5_000)

      [_first, {messages, _}] = Mock.calls()
      roles = Enum.map(messages, & &1.role)

      # Without the assistant turn the model is handed a result for a question it
      # has no record of asking.
      assert :assistant in roles
      assert Enum.find(messages, &(&1.role == :assistant)).content =~ "job_stats"
    end

    test "a job that needs no tool answers in one call" do
      Mock.script([{:ok, ~s({"answer": "42"})}])

      {:ok, id} = Jobs.add_job(%{prompt: "What is 6 times 7?", type: :assisted})
      job = await_status(id, :completed, 5_000)

      assert job.result == "42"
      assert Mock.call_count() == 1
    end
  end

  describe "limits" do
    test "a second tool request is refused rather than looped" do
      # Left uncapped, a confused model loops until the job deadline, burning
      # tokens and holding a concurrency slot the whole time.
      Mock.script([{:ok, ~s({"tool": "get_time"})}])

      {:ok, id} = Jobs.add_job(%{prompt: "loop please", type: :assisted})
      job = await_status(id, :failed, 20_000)

      # Exactly two calls per attempt, never three.
      assert Mock.call_count() == job.attempts * 2
      assert {:invalid_shape, message} = job.error
      assert message =~ "after one round"
    end

    test "an unknown tool name is a parse error, so it never reaches invoke" do
      Mock.script([
        {:ok, ~s({"tool": "rm_rf"})},
        {:ok, ~s({"answer": "recovered"})}
      ])

      {:ok, id} = Jobs.add_job(%{prompt: "x", type: :assisted})
      job = await_status(id, :completed, 8_000)

      # Retryable, so the model gets another sample — and the second attempt
      # answered properly.
      assert job.result == "recovered"
      assert job.attempts == 2
    end

    test "a malformed first reply is retryable like any other bad generation" do
      Mock.script([
        {:ok, "I'm afraid I can't do that"},
        {:ok, ~s({"answer": "second time lucky"})}
      ])

      {:ok, id} = Jobs.add_job(%{prompt: "x", type: :assisted})
      job = await_status(id, :completed, 8_000)

      assert job.result == "second time lucky"
      assert job.attempts == 2
    end

    test "a failed follow-up call fails the whole attempt" do
      Mock.script([
        {:ok, ~s({"tool": "get_time"})},
        {:error, Error.timeout()},
        {:ok, ~s({"tool": "get_time"})},
        {:ok, ~s({"answer": "eventually"})}
      ])

      {:ok, id} = Jobs.add_job(%{prompt: "x", type: :assisted})
      job = await_status(id, :completed, 8_000)

      # The attempt restarts from the beginning rather than resuming a
      # half-finished conversation.
      assert job.result == "eventually"
      assert job.attempts == 2
    end

    test "tool calls are counted" do
      Mock.script([{:ok, ~s({"tool": "get_time"})}, {:ok, ~s({"answer": "ok"})}])

      before = JobRunner.Jobs.Metrics.get(:tool_calls)
      {:ok, id} = Jobs.add_job(%{prompt: "x", type: :assisted})
      await_status(id, :completed, 5_000)

      assert JobRunner.Jobs.Metrics.get(:tool_calls) == before + 1
    end
  end

  describe "integration with the rest of the engine" do
    test "an assisted job is dispatched under the same concurrency ceiling" do
      Mock.script([{:sleep, 100, {:ok, ~s({"answer": "ok"})}}])

      for n <- 1..8, do: Jobs.add_job(%{prompt: "job #{n}", type: :assisted})

      samples =
        for _ <- 1..10,
            do:
              (
                Process.sleep(20)
                Queue.in_flight_count()
              )

      assert Enum.max(samples) <= 4
    end

    test "the type is registered and offered by the dashboard form" do
      assert :assisted in JobRunner.Jobs.JobType.names()
      assert {:ok, JobRunner.Jobs.JobType.Assisted} = JobRunner.Jobs.JobType.fetch(:assisted)
    end
  end
end
