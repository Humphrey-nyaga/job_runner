defmodule JobRunner.Jobs.Failure do
  @moduledoc """
  Decides what a failure *means*.

  `JobRunner.LLM.Error` records what happened; this module decides what to do
  about it, classified by who owns the fix:

    * `:systemic`  — the endpoint is unwell. Retried with backoff, and counts
      toward opening the circuit breaker.
    * `:retryable` — the endpoint is healthy; this generation was unusable.
      Retried, and must never trip the breaker.
    * `:permanent` — our request or configuration is wrong. Not retried, because
      an identical request produces an identical failure.

  The systemic/retryable split is load-bearing: if every failure counted toward
  the breaker, one malformed prompt could take the whole system offline.
  """

  alias JobRunner.LLM.Error

  @type class :: :systemic | :retryable | :permanent

  @doc """
  Classify a failure. Accepts an `%LLM.Error{}` from an adapter or an exit
  reason from a crashed task; both reach the Queue and both need a decision.
  """
  @spec classify(term()) :: class()

  # --- Systemic: the dependency itself is unwell ------------------------------

  # Nothing reached the server.
  def classify(%Error{class: :transport}), do: :systemic

  # May have been processed server-side, which is why it stays a distinct class
  # even though the policy matches :transport.
  def classify(%Error{class: :timeout}), do: :systemic

  # Providers reuse 429 for a permanently exhausted quota, which no backoff can
  # fix. The distinction is only in the body, hence Error's bounded preview.
  def classify(%Error{class: :http_status, code: 429, preview: preview})
      when is_binary(preview) do
    if String.contains?(preview, ["insufficient_quota", "exceeded your current quota"]) do
      :permanent
    else
      :systemic
    end
  end

  def classify(%Error{class: :http_status, code: 429}), do: :systemic
  def classify(%Error{class: :http_status, code: code}) when code in 500..599, do: :systemic

  # --- Permanent: repeating this changes nothing ------------------------------

  # A retry sends identical bytes and fails identically.
  def classify(%Error{class: :http_status, code: 400}), do: :permanent
  def classify(%Error{class: :http_status, code: 401}), do: :permanent
  def classify(%Error{class: :http_status, code: 403}), do: :permanent
  def classify(%Error{class: :http_status, code: 404}), do: :permanent
  def classify(%Error{class: :http_status, code: 422}), do: :permanent

  # Our configuration, not the endpoint's health: an identical budget truncates
  # identically, and thinking left enabled produces the same wall of reasoning.
  # Both carry a message naming the fix.
  def classify(%Error{class: :truncated}), do: :permanent
  def classify(%Error{class: :reasoning_only}), do: :permanent

  # 4xx that are genuinely transient
  def classify(%Error{class: :http_status, code: 408}), do: :systemic
  def classify(%Error{class: :http_status, code: 409}), do: :retryable
  def classify(%Error{class: :http_status, code: 425}), do: :retryable

  # Unknown 4xx: assume permanent.
  def classify(%Error{class: :http_status, code: code}) when code in 400..499, do: :permanent

  def classify(%Error{class: :malformed_response}), do: :retryable
  def classify(%Error{class: :empty_response}), do: :retryable

  def classify({:invalid_json, _}), do: :retryable
  def classify({:invalid_shape, _}), do: :retryable

  def classify(:job_timeout), do: :systemic

  # --- Crashes

  # A bug in our code, not a statement about the endpoint, so it must never trip
  # the breaker. Retryable, but on the reduced budget below: most exceptions are
  # deterministic, so repeating one four times is noise rather than resilience.
  def classify({:crash, _reason}), do: :retryable

  # Unknown failures are retryable: a bounded number of wasted retries is a
  # cheaper mistake than discarding work that would have succeeded.
  def classify(_other), do: :retryable

  @doc "True when the failure should be retried at all."
  @spec retry?(class()) :: boolean()
  def retry?(:permanent), do: false
  def retry?(_), do: true

  @doc """
  True when the failure is evidence about the endpoint's health, and should
  count toward opening the circuit breaker.
  """
  @spec systemic?(class()) :: boolean()
  def systemic?(:systemic), do: true
  def systemic?(_), do: false

  @doc """
  Attempts allowed for an unexpected crash, regardless of `max_attempts`.

  Deliberately small: dependency failures are usually transient and deserve the
  full budget, whereas a `FunctionClauseError` is usually deterministic.
  """
  @spec crash_retry_budget() :: pos_integer()
  def crash_retry_budget, do: 2
end
