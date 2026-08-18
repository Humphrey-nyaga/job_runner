defmodule JobRunner.LLM.Error do
  @moduledoc """
  A normalised, bounded description of a failed LLM call.

  Every adapter must translate its provider's failures into this struct, so the
  job engine never pattern-matches on `Req`, `Mint`, or a provider's error JSON.
  That is what keeps the integration's quirks inside the adapter.

  Two deliberate properties:

    * **Bounded.** Response bodies are truncated to #{100} characters before
      being stored. Errors end up in the dead letter queue and are broadcast to
      the dashboard; retaining whole provider payloads there is an unbounded
      memory leak with a privacy problem attached.

    * **Policy-free.** This struct records *what happened*. It deliberately does
      not say whether the failure is worth retrying — that is
      `JobRunner.Jobs.Failure`'s job. Keeping observation and policy apart means
      the retry rules can change without touching any adapter.
  """

  @body_preview_limit 300

  @type class ::
          :transport
          | :timeout
          | :http_status
          | :malformed_response
          | :empty_response
          | :reasoning_only
          | :truncated

  @type t :: %__MODULE__{
          class: class(),
          code: pos_integer() | nil,
          message: String.t(),
          preview: String.t() | nil,
          occurred_at: DateTime.t()
        }

  @enforce_keys [:class, :message, :occurred_at]
  defstruct [:class, :code, :message, :preview, :occurred_at]

  @doc "The connection never produced a response: refused, DNS failure, TLS failure."
  @spec transport(term()) :: t()
  def transport(reason) do
    new(:transport, nil, "transport error: #{inspect_reason(reason)}", nil)
  end

  @doc """
  A timeout, annotated with enough detail to tell *which* timeout fired.

  Req surfaces a connect timeout and a receive timeout identically, as
  `%Req.TransportError{reason: :timeout}`. That ambiguity is expensive to debug:
  "request timed out" is equally consistent with the host being unreachable and
  with the model taking its time, and those have completely different fixes.

  Elapsed time disambiguates them. A failure at ~5s against a 5s connect budget
  and a 120s receive budget could only have been the connection.
  """
  @spec timeout(non_neg_integer() | nil, keyword()) :: t()
  def timeout(elapsed_ms \\ nil, opts \\ [])

  def timeout(nil, _opts), do: new(:timeout, nil, "request timed out", nil)

  def timeout(elapsed_ms, opts) do
    connect = Keyword.get(opts, :connect_timeout)
    receive_timeout = Keyword.get(opts, :receive_timeout)

    # Receive is checked first: it is usually the larger budget, but not always
    # (a test may set it to 1ms), and whichever budget was actually exceeded is
    # the one that fired.
    likely =
      cond do
        is_integer(receive_timeout) and elapsed_ms + 100 >= receive_timeout ->
          "likely RECEIVE timeout — endpoint reachable but too slow to answer"

        is_integer(connect) and elapsed_ms + 500 >= connect ->
          "likely CONNECT timeout — host unreachable (VPN down? wrong base_url?)"

        true ->
          "timed out"
      end

    new(
      :timeout,
      nil,
      "#{likely} after #{elapsed_ms}ms (connect=#{inspect(connect)} receive=#{inspect(receive_timeout)})",
      nil
    )
  end

  @doc "A response arrived with a non-2xx status."
  @spec http_status(pos_integer(), term()) :: t()
  def http_status(status, body) do
    new(:http_status, status, "http #{status}", preview(body))
  end

  @doc "A 2xx response whose shape we could not read."
  @spec malformed_response(term()) :: t()
  def malformed_response(body) do
    new(:malformed_response, nil, "unexpected response shape", preview(body))
  end

  @doc """
  The model spent its whole budget reasoning and never produced an answer.

  Reasoning models (Qwen3, and OpenAI's o-series) return chain-of-thought in a
  separate `reasoning` field and leave `content` null until thinking completes.
  A null `content` therefore means "it never finished thinking", which is a
  different problem from a malformed envelope and has a different fix — disable
  thinking, or raise the token budget.
  """
  @spec reasoning_only(non_neg_integer()) :: t()
  def reasoning_only(reasoning_length) do
    new(
      :reasoning_only,
      nil,
      "model produced #{reasoning_length} chars of reasoning but no content " <>
        "(set chat_template_kwargs.enable_thinking=false, or raise max_tokens)",
      nil
    )
  end

  @doc """
  The response was cut off by the token limit.

  Worth its own class rather than being accepted silently: a truncated answer is
  not a short answer. For a structured job type it is invalid JSON, and for a
  text job it is a sentence that stops mid-
  """
  @spec truncated(String.t() | nil) :: t()
  def truncated(partial) do
    new(
      :truncated,
      nil,
      "response hit the max_tokens limit before finishing — raise max_tokens",
      preview(partial)
    )
  end

  @doc "A well-formed 2xx response carrying no usable content."
  @spec empty_response() :: t()
  def empty_response do
    new(:empty_response, nil, "response contained no content", nil)
  end

  defp new(class, code, message, preview) do
    %__MODULE__{
      class: class,
      code: code,
      message: message,
      preview: preview,
      occurred_at: DateTime.utc_now()
    }
  end

  # Exception structs print their own message cleanly; anything else we inspect.
  defp inspect_reason(%{__exception__: true} = exception), do: Exception.message(exception)
  defp inspect_reason(reason), do: inspect(reason)

  defp preview(body) when is_binary(body), do: truncate(body)
  defp preview(nil), do: nil

  defp preview(body),
    do: body |> inspect(limit: 10, printable_limit: @body_preview_limit) |> truncate()

  defp truncate(string) when byte_size(string) <= @body_preview_limit, do: string
  defp truncate(string), do: String.slice(string, 0, @body_preview_limit) <> "…"
end
