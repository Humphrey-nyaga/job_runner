defmodule JobRunner.Jobs.JobTest do
  @moduledoc """
  Admission validation and derived predicates. Pure — no processes, no network.
  """

  use ExUnit.Case, async: true

  alias JobRunner.Jobs.Job

  describe "new/1 validation (rejects at admission, not at dispatch)" do
    test "accepts a reasonable prompt and defaults sensibly" do
      assert {:ok, job} = Job.new(%{prompt: "summarise this ledger entry"})

      assert job.status == :pending
      assert job.priority == :normal
      assert job.attempts == 0
      assert job.attempt_id == 0
      assert job.history == []
      assert job.max_attempts == 5
      assert byte_size(job.id) > 0
    end

    test "rejects a blank or whitespace-only prompt" do
      assert {:error, :invalid_prompt} = Job.new(%{prompt: ""})
      assert {:error, :invalid_prompt} = Job.new(%{prompt: "   \n\t "})
      assert {:error, :invalid_prompt} = Job.new(%{prompt: nil})
      assert {:error, :invalid_prompt} = Job.new(%{prompt: 42})
    end

    test "rejects an oversized prompt before it can become a provider 400" do
      big = String.duplicate("x", 30_000)
      assert {:error, :prompt_too_large} = Job.new(%{prompt: big})
    end

    test "rejects a max_attempts that would make the job undispatchable" do
      # A job whose budget is already spent can never be dispatched, and nothing
      # fails a pending job either — it would sit at :pending forever, invisibly.
      assert {:error, :invalid_max_attempts} = Job.new(%{prompt: "p", max_attempts: 0})
      assert {:error, :invalid_max_attempts} = Job.new(%{prompt: "p", max_attempts: -5})
      assert {:error, :invalid_max_attempts} = Job.new(%{prompt: "p", max_attempts: "many"})

      # `nil` means "not specified" rather than "zero", so it falls back to the
      # configured default like any other omitted field.
      assert {:ok, %Job{max_attempts: 5}} = Job.new(%{prompt: "p", max_attempts: nil})

      # And an absurd budget is refused too: 999 attempts against a shared
      # endpoint is a denial of service, not resilience.
      assert {:error, :invalid_max_attempts} = Job.new(%{prompt: "p", max_attempts: 999})

      assert {:ok, %Job{max_attempts: 3}} = Job.new(%{prompt: "p", max_attempts: 3})
    end

    test "trims the prompt" do
      assert {:ok, %Job{prompt: "hello"}} = Job.new(%{prompt: "  hello  "})
    end

    test "accepts priorities as atoms or strings, rejects anything else" do
      assert {:ok, %Job{priority: :high}} = Job.new(%{prompt: "p", priority: :high})
      assert {:ok, %Job{priority: :low}} = Job.new(%{prompt: "p", priority: "low"})
      assert {:error, :invalid_priority} = Job.new(%{prompt: "p", priority: :urgent})
    end

    test "ids are unique" do
      ids = for _ <- 1..500, do: elem(Job.new(%{prompt: "p"}), 1).id
      assert length(Enum.uniq(ids)) == 500
    end
  end

  describe "derived predicates" do
    setup do
      {:ok, job} = Job.new(%{prompt: "p"})
      {:ok, job: job}
    end

    test "retrying?/1 distinguishes a fresh pending job from one awaiting backoff", %{job: job} do
      # Waiting on a backoff is :pending with next_run_at set, not a fifth
      # status. This predicate is how the UI labels it without inventing one.
      refute Job.retrying?(job)

      waiting = %{job | attempts: 1, next_run_at: DateTime.add(DateTime.utc_now(), 5)}
      assert Job.retrying?(waiting)

      running = %{job | status: :running, attempts: 1}
      refute Job.retrying?(running)
    end

    test "terminal?/1", %{job: job} do
      refute Job.terminal?(job)
      refute Job.terminal?(%{job | status: :running})
      assert Job.terminal?(%{job | status: :completed})
      assert Job.terminal?(%{job | status: :failed})
    end

    test "exhausted?/1 fires exactly at the budget, not one past it", %{job: job} do
      refute Job.exhausted?(%{job | attempts: 4, max_attempts: 5})
      assert Job.exhausted?(%{job | attempts: 5, max_attempts: 5})
    end

    test "delay_until_runnable/2 never returns a negative delay", %{job: job} do
      now = DateTime.utc_now()

      assert Job.delay_until_runnable(job, now) == 0

      past = %{job | next_run_at: DateTime.add(now, -10, :second)}
      assert Job.delay_until_runnable(past, now) == 0

      future = %{job | next_run_at: DateTime.add(now, 2, :second)}
      delay = Job.delay_until_runnable(future, now)
      assert delay > 1_900 and delay <= 2_000
    end
  end
end
