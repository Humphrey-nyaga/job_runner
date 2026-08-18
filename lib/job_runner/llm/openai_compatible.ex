defmodule JobRunner.LLM.OpenAICompatible do
  @moduledoc """
  Adapter for any endpoint speaking the OpenAI `/v1/chat/completions` protocol.

  This is deliberately **one** adapter rather than two. The internal vLLM
  endpoint and the OpenAI API accept the same request shape and return the same
  response envelope, so the difference between them is `base_url`, `model`, and
  `api_key` — configuration, not behaviour. Ollama, LM Studio, Groq,
  Together and vLLM all fit here too.

  ## The one non-obvious line

      retry: false

  `Req` retries some failures by default. That must be off. Retry policy lives in
  the Queue, which owns the attempt count and frees its concurrency slot before
  waiting. An adapter retrying underneath would silently multiply the
  configured budget — `max_attempts: 5` becomes 15 real calls — and would block a
  worker slot while it slept. Every adapter in this system performs exactly one
  attempt.
  """

  @behaviour JobRunner.LLM

  alias JobRunner.LLM.Error

  require Logger

  @impl JobRunner.LLM
  def chat(messages, opts) do
    # Elapsed time is measured so a timeout can say *which* timeout fired — Req
    # reports a connect and a receive timeout identically, and they have very
    # different fixes.
    {elapsed_us, response} =
      :timer.tc(fn -> opts |> build_request(messages) |> Req.post() end)

    handle_response(response, div(elapsed_us, 1000), opts)
  end

  defp build_request(opts, messages) do
    base_url = Keyword.fetch!(opts, :base_url)
    model = Keyword.fetch!(opts, :model)
    api_key = Keyword.get(opts, :api_key) || "not-required"

    body =
      %{model: model, messages: Enum.map(messages, &encode_message/1)}
      |> maybe_put(token_param(opts), Keyword.get(opts, :max_tokens))
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
      |> maybe_put(:response_format, Keyword.get(opts, :response_format))
      |> maybe_put(:chat_template_kwargs, Keyword.get(opts, :chat_template_kwargs))

    Req.new(
      base_url: base_url,
      url: "/v1/chat/completions",
      json: body,
      auth: {:bearer, api_key},
      # One attempt only — see moduledoc.
      retry: false,
      # Fail fast on a dead host rather than hanging on connect.
      connect_options: [timeout: Keyword.get(opts, :connect_timeout, 5_000)],
      receive_timeout: Keyword.get(opts, :receive_timeout, 45_000)
    )
  end

  # Roles cross the wire as strings; we keep them as atoms internally so a typo
  # is a compile-time-ish error rather than a silently ignored field.
  defp encode_message(%{role: role, content: content}) do
    %{role: to_string(role), content: content}
  end

  # Every optional field is omitted rather than defaulted. Providers in this
  # family disagree about which fields they accept, and sending a parameter a
  # server rejects is a hard 400 — so "not configured" must mean "not sent",
  # never "sent with our guess".
  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  # Dialect difference, not a behaviour difference: vLLM and older OpenAI models
  # take `max_tokens`; newer OpenAI reasoning models require
  # `max_completion_tokens` and reject the old name outright. Configuring the
  # field name keeps that quirk inside this module.
  defp token_param(opts), do: Keyword.get(opts, :token_param, :max_tokens)

  # --- Response handling -----------------------------------------------------
  #
  # Every branch returns a tagged tuple; nothing raises. An
  # exception escaping this module means we hit a case we did not anticipate,
  # which is exactly the signal we want.

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _elapsed, _opts)
       when status in 200..299 do
    extract_content(body)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _elapsed, _opts) do
    {:error, Error.http_status(status, body)}
  end

  # Req surfaces both a connect timeout and a receive timeout as a transport
  # error with reason :timeout. It gets its own class because the retry story
  # differs from a refused connection: a timeout may well have been processed
  # server-side, a refusal certainly was not. Elapsed time is passed through so
  # the message can name which budget was exhausted.
  defp handle_response({:error, %Req.TransportError{reason: :timeout}}, elapsed, opts) do
    {:error,
     Error.timeout(elapsed,
       connect_timeout: Keyword.get(opts, :connect_timeout, 5_000),
       receive_timeout: Keyword.get(opts, :receive_timeout, 45_000)
     )}
  end

  defp handle_response({:error, %Req.TransportError{} = error}, _elapsed, _opts) do
    {:error, Error.transport(error)}
  end

  defp handle_response({:error, reason}, _elapsed, _opts) do
    {:error, Error.transport(reason)}
  end

  # One clause over the whole choice, because the diagnosis depends on the
  # *combination* of content, reasoning and finish_reason — and a real vLLM
  # response carries all three at once. Ordering matters: a reasoning model that
  # ran out of budget reports content:null AND finish_reason:"length", and
  # "it never stopped thinking" is the actionable cause while "it was truncated"
  # is only the symptom.
  defp extract_content(%{"choices" => [choice | _]}) when is_map(choice) do
    message = Map.get(choice, "message") || %{}
    content = Map.get(message, "content")
    reasoning = Map.get(message, "reasoning") || Map.get(message, "reasoning_content")
    truncated? = Map.get(choice, "finish_reason") == "length"

    cond do
      # Cause first: thinking consumed the budget and no answer was produced.
      is_nil(content) and is_binary(reasoning) ->
        {:error, Error.reasoning_only(String.length(reasoning))}

      # Real content, but cut off. Not a short answer — for a structured job type
      # this is invalid JSON, and accepting it turns a budget problem into a
      # parsing problem one layer up.
      is_binary(content) and truncated? ->
        {:error, Error.truncated(content)}

      is_binary(content) ->
        case String.trim(content) do
          "" -> {:error, Error.empty_response()}
          trimmed -> {:ok, trimmed}
        end

      truncated? ->
        {:error, Error.truncated(nil)}

      true ->
        {:error, Error.malformed_response(message)}
    end
  end

  # A 200 that does not carry the envelope we expect. This happens for real:
  # a proxy returning an HTML error page with status 200, a model server
  # returning `{"error": ...}`, or `choices: []` under load. It is retryable,
  # so it must be an error value rather than a MatchError crash.
  defp extract_content(body) do
    {:error, Error.malformed_response(body)}
  end

  @doc """
  Liveness check against `GET /health`.

  Not part of the `JobRunner.LLM` behaviour — it is an operational convenience
  for the README and the dashboard, and not every provider offers it (OpenAI
  does not). Kept out of the behaviour so the contract stays minimal.
  """
  @spec health(keyword()) :: :ok | {:error, Error.t()}
  def health(opts \\ []) do
    opts = JobRunner.LLM.config(opts)

    req =
      Req.new(
        base_url: Keyword.fetch!(opts, :base_url),
        url: "/health",
        retry: false,
        receive_timeout: 5_000
      )

    case Req.get(req) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, Error.http_status(status, body)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.timeout()}

      {:error, reason} ->
        {:error, Error.transport(reason)}
    end
  end
end
