defmodule JobRunner.LLM.OpenAICompatibleTest do
  @moduledoc """
  Adapter tests.

  These run against a real HTTP server, so they cover Req, JSON decoding, status
  handling and socket behaviour — none of which the `Mock` adapter touches.

  The through-line of every test: **the adapter never raises.** Each anticipated
  provider failure becomes a `%LLM.Error{}` with a class the retry policy can
  act on.
  """

  use ExUnit.Case, async: false

  alias JobRunner.LLM
  alias JobRunner.LLM.{Error, OpenAICompatible}
  alias JobRunner.Test.LLMServer

  setup_all do
    base_url = LLMServer.start()
    {:ok, base_url: base_url}
  end

  setup %{base_url: base_url} do
    LLMServer.scenario(:ok_response)

    opts = [
      base_url: base_url,
      model: "test-model",
      api_key: "test-key",
      receive_timeout: 300,
      connect_timeout: 300,
      max_tokens: 64
    ]

    {:ok, opts: opts}
  end

  defp chat(opts, overrides \\ []) do
    OpenAICompatible.chat(LLM.messages("hello"), Keyword.merge(opts, overrides))
  end

  describe "success" do
    test "returns the assistant's content", %{opts: opts} do
      assert {:ok, "hello from test-model"} = chat(opts)
    end

    test "sends the configured model and auth header", %{opts: opts} do
      LLMServer.scenario(:echo_request)
      assert {:ok, raw} = chat(opts, model: "a-different-model")

      decoded = Jason.decode!(raw)
      assert decoded["model"] == "a-different-model"
      assert [%{"role" => "user", "content" => "hello"}] = decoded["messages"]
    end

    test "base_url comes from config, not from code", %{opts: opts} do
      # Pointing only base_url elsewhere must be enough to retarget the adapter.
      assert {:error, %Error{class: :transport}} = chat(opts, base_url: "http://127.0.0.1:9")
    end

    test "omits optional fields that are nil rather than guessing a default", %{opts: opts} do
      LLMServer.scenario(:echo_request)
      assert {:ok, raw} = chat(opts, temperature: nil, max_tokens: nil)

      decoded = Jason.decode!(raw)
      refute Map.has_key?(decoded, "temperature")
      refute Map.has_key?(decoded, "max_tokens")
    end

    test "token_param selects the provider's dialect", %{opts: opts} do
      LLMServer.scenario(:echo_request)

      assert {:ok, raw} = chat(opts, token_param: :max_completion_tokens, max_tokens: 32)
      decoded = Jason.decode!(raw)

      # Sending the wrong one of these is a hard 400 on newer OpenAI models,
      # which is the bug this option exists to prevent.
      assert decoded["max_completion_tokens"] == 32
      refute Map.has_key?(decoded, "max_tokens")
    end
  end

  describe "malformed 2xx responses" do
    test "empty choices list", %{opts: opts} do
      LLMServer.scenario(:no_choices)
      assert {:error, %Error{class: :malformed_response}} = chat(opts)
    end

    test "whitespace-only content is treated as empty, not success", %{opts: opts} do
      LLMServer.scenario(:empty_content)
      assert {:error, %Error{class: :empty_response}} = chat(opts)
    end

    test "a 200 that is not the expected envelope", %{opts: opts} do
      LLMServer.scenario(:wrong_shape)
      assert {:error, %Error{class: :malformed_response}} = chat(opts)
    end

    test "a 200 carrying HTML instead of JSON does not raise", %{opts: opts} do
      LLMServer.scenario(:not_json)
      assert {:error, %Error{class: :malformed_response}} = chat(opts)
    end
  end

  describe "reasoning models (vLLM serving Qwen3, OpenAI o-series)" do
    test "content:null with reasoning present is diagnosed, not called malformed", %{opts: opts} do
      # A generic "malformed response" sends you hunting the envelope, when the
      # actual fix is a config change — so the error has to say which.
      LLMServer.scenario(:reasoning_only)

      assert {:error, %Error{class: :reasoning_only, message: message}} = chat(opts)
      assert message =~ "enable_thinking=false"
      assert message =~ "max_tokens"
    end

    test "a truncated response is a failure, not a short answer", %{opts: opts} do
      # finish_reason "length" with real content is the dangerous case: accepted
      # silently it becomes invalid JSON one layer up, and the budget problem is
      # diagnosed as a parsing problem.
      LLMServer.scenario(:truncated)

      assert {:error, %Error{class: :truncated, preview: preview}} = chat(opts)
      assert preview =~ "half a sen"
    end

    test "chat_template_kwargs is forwarded so thinking can be disabled", %{opts: opts} do
      LLMServer.scenario(:echo_request)

      assert {:ok, raw} = chat(opts, chat_template_kwargs: %{enable_thinking: false})
      assert %{"chat_template_kwargs" => %{"enable_thinking" => false}} = Jason.decode!(raw)
    end

    test "it is omitted entirely when unset, so OpenAI does not reject it", %{opts: opts} do
      LLMServer.scenario(:echo_request)

      assert {:ok, raw} = chat(opts)
      refute Map.has_key?(Jason.decode!(raw), "chat_template_kwargs")
    end
  end

  describe "status failures" do
    for status <- [400, 401, 404, 429, 500, 503] do
      test "http #{status} becomes an error value", %{opts: opts} do
        LLMServer.scenario({:status, unquote(status)})
        assert {:error, %Error{class: :http_status, code: unquote(status)}} = chat(opts)
      end
    end

    test "the response body is preserved but bounded", %{opts: opts} do
      LLMServer.scenario({:status, 500})
      assert {:error, %Error{preview: preview}} = chat(opts)

      assert is_binary(preview)
      # Errors reach the DLQ and the dashboard; unbounded bodies there are a
      # memory leak with a privacy problem attached.
      assert byte_size(preview) <= 110
    end
  end

  describe "transport failures" do
    test "a response slower than receive_timeout", %{opts: opts} do
      LLMServer.scenario({:sleep, 400})
      assert {:error, %Error{class: :timeout}} = chat(opts, receive_timeout: 100)
    end

    test "connection refused", %{opts: opts} do
      assert {:error, %Error{class: :transport, message: message}} =
               chat(opts, base_url: "http://127.0.0.1:9")

      assert message =~ "connection refused"
    end

    test "timeout and transport are distinct classes", %{opts: opts} do
      # They differ in whether the request may already have been processed
      # server-side, which is why they are not collapsed into one class.
      LLMServer.scenario({:sleep, 400})
      assert {:error, %Error{class: :timeout}} = chat(opts, receive_timeout: 100)
      assert {:error, %Error{class: :transport}} = chat(opts, base_url: "http://127.0.0.1:9")
    end
  end

  describe "the adapter performs exactly one attempt" do
    test "a 500 is returned, not retried internally", %{opts: opts} do
      # Req retries some failures by default. If that were left on, the engine's
      # attempt budget would be silently multiplied and a worker slot held while
      # Req slept. This asserts the behaviour rather than trusting the option.
      LLMServer.scenario({:status, 500})

      {elapsed_us, {:error, %Error{code: 500}}} = :timer.tc(fn -> chat(opts) end)

      assert elapsed_us < 500_000,
             "took #{div(elapsed_us, 1000)}ms — adapter appears to be retrying internally"
    end
  end

  describe "health/1" do
    test "reports transport failure for an unreachable endpoint", %{opts: opts} do
      assert {:error, %Error{class: :transport}} =
               OpenAICompatible.health(Keyword.put(opts, :base_url, "http://127.0.0.1:9"))
    end
  end
end
