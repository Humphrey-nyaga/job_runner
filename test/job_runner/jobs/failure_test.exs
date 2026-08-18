defmodule JobRunner.Jobs.FailureTest do
  @moduledoc """
  Classification is the policy layer, so every failure mode the adapter can
  produce has an assertion here. These are the cheapest tests in the suite and cover the
  decisions most likely to be argued about in review.
  """

  use ExUnit.Case, async: true

  alias JobRunner.Jobs.Failure
  alias JobRunner.LLM.Error

  describe "systemic — evidence the endpoint is unwell (trips the breaker)" do
    test "F1 transport failure" do
      assert Failure.classify(Error.transport(:econnrefused)) == :systemic
    end

    test "F2 timeout" do
      assert Failure.classify(Error.timeout()) == :systemic
    end

    test "F3 rate limiting" do
      assert Failure.classify(Error.http_status(429, "slow down")) == :systemic
    end

    test "a 429 for rate limiting is transient" do
      assert Failure.classify(Error.http_status(429, "Rate limit reached")) == :systemic
    end

    test "F4 server errors" do
      for status <- [500, 502, 503, 504, 599] do
        assert Failure.classify(Error.http_status(status, "")) == :systemic,
               "expected #{status} to be systemic"
      end
    end

    test "408 request timeout is transient despite being a 4xx" do
      assert Failure.classify(Error.http_status(408, "")) == :systemic
    end

    test "the Queue's own deadline" do
      assert Failure.classify(:job_timeout) == :systemic
    end
  end

  describe "permanent — repeating this changes nothing (straight to DLQ)" do
    test "F5/F6 client errors" do
      for status <- [400, 401, 403, 404, 422] do
        assert Failure.classify(Error.http_status(status, "")) == :permanent,
               "expected #{status} to be permanent"
      end
    end

    test "a 429 for an exhausted quota is permanent, not transient" do
      # Providers reuse 429 for both. Backoff fixes the first and never fixes the
      # second, so treating them alike burns the whole budget and opens the
      # breaker on a condition no retry can clear.
      body = ~s({"error":{"code":"insufficient_quota","message":"exceeded your current quota"}})

      assert Failure.classify(Error.http_status(429, body)) == :permanent
      refute Failure.systemic?(Failure.classify(Error.http_status(429, body)))
    end

    test "our own misconfiguration is permanent, not retryable" do
      # Nobody truncated the response except us: max_tokens is our setting, so a
      # retry sends the identical budget and truncates identically. Same for a
      # reasoning model that never produced content — thinking was left on.
      assert Failure.classify(Error.truncated("half a sen")) == :permanent
      assert Failure.classify(Error.reasoning_only(500)) == :permanent
    end

    test "and never trips the circuit breaker" do
      # The endpoint answered promptly with a 200. It is healthy; we are wrong.
      refute Failure.systemic?(Failure.classify(Error.reasoning_only(500)))
      refute Failure.systemic?(Failure.classify(Error.truncated("half")))
    end

    test "425 Too Early is retryable despite being a 4xx" do
      assert Failure.classify(Error.http_status(425, "")) == :retryable
    end

    test "an unrecognised 4xx defaults to permanent" do
      # Guessing "retryable" here would burn the whole budget on a request that
      # cannot succeed.
      assert Failure.classify(Error.http_status(418, "teapot")) == :permanent
    end

    test "permanent failures are not retried" do
      refute Failure.retry?(:permanent)
      assert Failure.retry?(:retryable)
      assert Failure.retry?(:systemic)
    end
  end

  describe "retryable — this attempt failed, the endpoint is fine" do
    test "F7 malformed envelope" do
      assert Failure.classify(Error.malformed_response(%{})) == :retryable
    end

    test "F8 empty content" do
      assert Failure.classify(Error.empty_response()) == :retryable
    end

    test "F9/F10 structured-output failures" do
      assert Failure.classify({:invalid_json, "not json"}) == :retryable
      assert Failure.classify({:invalid_shape, [:missing_summary]}) == :retryable
    end

    test "F11 an unexpected crash in our own code" do
      assert Failure.classify({:crash, %FunctionClauseError{}}) == :retryable
    end

    test "an unknown failure is retryable, bounded by the attempt budget" do
      assert Failure.classify(:something_new) == :retryable
      assert Failure.classify({:weird, :tuple}) == :retryable
    end
  end

  describe "only endpoint health trips the circuit breaker" do
    test "systemic failures count" do
      assert Failure.systemic?(Failure.classify(Error.timeout()))
      assert Failure.systemic?(Failure.classify(Error.transport(:econnrefused)))
      assert Failure.systemic?(Failure.classify(Error.http_status(503, "")))
    end

    test "a bad prompt does NOT count" do
      # This is the guard that stops one malformed job taking the system offline.
      refute Failure.systemic?(Failure.classify(Error.http_status(400, "")))
    end

    test "a model returning garbage does NOT count" do
      # The server answered promptly and correctly at the HTTP layer; it is
      # healthy. Only the generation was unusable.
      refute Failure.systemic?(Failure.classify(Error.malformed_response("<html>")))
      refute Failure.systemic?(Failure.classify({:invalid_json, "nope"}))
    end

    test "our own bug does NOT count" do
      refute Failure.systemic?(Failure.classify({:crash, %RuntimeError{}}))
    end
  end

  describe "crash budget" do
    test "is smaller than the full attempt budget" do
      # Most exceptions are deterministic; repeating one four times is noise,
      # not resilience.
      assert Failure.crash_retry_budget() < 5
      assert Failure.crash_retry_budget() >= 1
    end
  end
end
