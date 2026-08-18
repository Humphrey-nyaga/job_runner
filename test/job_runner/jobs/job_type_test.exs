defmodule JobRunner.Jobs.JobTypeTest do
  @moduledoc """
  Prompt construction and result validation.

  Pure and fast. Every case here is a real thing an LLM does — these are not
  hypothetical malformed inputs, they are the actual output modes of a model
  asked politely for JSON.
  """

  use ExUnit.Case, async: true

  alias JobRunner.Jobs.{Job, JobType}
  alias JobRunner.Jobs.JobType.{Echo, Summarize}

  defp job(attrs \\ %{}) do
    {:ok, job} = Job.new(Map.merge(%{prompt: "the quarterly ledger"}, attrs))
    job
  end

  describe "registry" do
    test "resolves known types" do
      assert {:ok, Echo} = JobType.fetch(:echo)
      assert {:ok, Summarize} = JobType.fetch(:summarize)
    end

    test "rejects unknown types" do
      assert {:error, :unknown_type} = JobType.fetch(:nonsense)
    end

    test "an unknown type is refused at admission, not at dispatch" do
      # It could never succeed, so it must never become a job that burns five
      # attempts failing identically.
      assert {:error, :unknown_type} = Job.new(%{prompt: "x", type: :nonsense})
      assert {:error, :unknown_type} = Job.new(%{prompt: "x", type: "nonsense"})
    end
  end

  describe "Echo" do
    test "sends the prompt unchanged" do
      assert [%{role: :user, content: "the quarterly ledger"}] = Echo.messages(job())
    end

    test "keeps whatever text comes back" do
      assert {:ok, "anything at all"} = Echo.parse("anything at all")
    end
  end

  describe "Summarize prompt" do
    test "sends a system message naming the schema and the closed category set" do
      assert [%{role: :system, content: system}, %{role: :user, content: user}] =
               Summarize.messages(job())

      assert system =~ "summary"
      assert system =~ "category"
      for category <- Summarize.categories(), do: assert(system =~ Atom.to_string(category))
      assert user =~ "the quarterly ledger"
    end

    test "requests JSON mode from providers that support it" do
      assert [response_format: %{type: "json_object"}] = Summarize.llm_opts()
    end
  end

  describe "Summarize accepts valid output" do
    test "a clean JSON object" do
      json = ~s({"summary": "Revenue rose 4%.", "category": "finance"})

      assert {:ok, %{summary: "Revenue rose 4%.", category: :finance}} = Summarize.parse(json)
    end

    test "every allowed category" do
      for category <- Summarize.categories() do
        json = ~s({"summary": "x", "category": "#{Atom.to_string(category)}"})
        assert {:ok, %{category: parsed}} = Summarize.parse(json)
        assert parsed == category
      end
    end

    test "normalises case and whitespace in the category" do
      json = ~s({"summary": "x", "category": "  FINANCE "})
      assert {:ok, %{category: :finance}} = Summarize.parse(json)
    end
  end

  describe "Summarize tolerates how models actually reply" do
    test "a ```json fence" do
      # Models do this constantly, even when told not to. Rejecting it would
      # cost a whole extra call for output that is perfectly usable.
      fenced = "```json\n{\"summary\": \"ok\", \"category\": \"legal\"}\n```"

      assert {:ok, %{summary: "ok", category: :legal}} = Summarize.parse(fenced)
    end

    test "a bare ``` fence" do
      fenced = "```\n{\"summary\": \"ok\", \"category\": \"other\"}\n```"
      assert {:ok, %{category: :other}} = Summarize.parse(fenced)
    end

    test "JSON preceded by chatty prose" do
      chatty = ~s(Sure! Here is the JSON:\n{"summary": "ok", "category": "technical"})

      assert {:ok, %{category: :technical}} = Summarize.parse(chatty)
    end

    test "surrounding whitespace" do
      assert {:ok, _} = Summarize.parse("\n\n  {\"summary\":\"s\",\"category\":\"other\"}  \n")
    end
  end

  describe "Summarize rejects unusable output" do
    test "not JSON at all" do
      assert {:error, {:invalid_json, _}} = Summarize.parse("I'm sorry, I can't do that.")
    end

    test "truncated JSON" do
      assert {:error, {:invalid_json, _}} = Summarize.parse(~s({"summary": "unfinis))
    end

    test "missing summary" do
      assert {:error, {:invalid_shape, message}} = Summarize.parse(~s({"category": "legal"}))
      assert message =~ "summary"
    end

    test "missing category" do
      assert {:error, {:invalid_shape, message}} = Summarize.parse(~s({"summary": "ok"}))
      assert message =~ "category"
    end

    test "empty summary" do
      json = ~s({"summary": "   ", "category": "legal"})
      assert {:error, {:invalid_shape, _}} = Summarize.parse(json)
    end

    test "summary of the wrong type" do
      assert {:error, {:invalid_shape, _}} =
               Summarize.parse(~s({"summary": 42, "category": "legal"}))
    end

    test "a category outside the closed set" do
      # The whitelist is the point. Accepting an invented category would leave
      # consumers handling an open-ended set — structure in name only.
      json = ~s({"summary": "ok", "category": "miscellaneous"})

      assert {:error, {:invalid_shape, message}} = Summarize.parse(json)
      assert message =~ "miscellaneous"
    end

    test "valid JSON that is not an object" do
      assert {:error, {:invalid_shape, _}} = Summarize.parse("[1, 2, 3]")
      assert {:error, {:invalid_shape, _}} = Summarize.parse(~s("just a string"))
    end

    test "rejections stay bounded — they are stored and broadcast" do
      huge = String.duplicate("not json ", 500)
      assert {:error, {:invalid_json, preview}} = Summarize.parse(huge)
      assert byte_size(preview) <= 110
    end
  end

  describe "rejections classify correctly" do
    alias JobRunner.Jobs.Failure

    test "parse failures are retryable" do
      # Resampling a non-deterministic generator is a reasonable response to a
      # bad sample.
      assert Failure.classify({:invalid_json, "x"}) == :retryable
      assert Failure.classify({:invalid_shape, "x"}) == :retryable
    end

    test "parse failures never trip the circuit breaker" do
      # The endpoint answered promptly and correctly at the HTTP layer. It is
      # healthy; only this generation was unusable.
      refute Failure.systemic?(Failure.classify({:invalid_json, "x"}))
      refute Failure.systemic?(Failure.classify({:invalid_shape, "x"}))
    end
  end
end
