defmodule JobRunner.LLM do
  @moduledoc """
  The seam between the job engine and whatever generates text.

  A behaviour with a single callback, plus the entry point that resolves the
  configured adapter at runtime. Nothing outside `JobRunner.LLM.*` knows which
  provider is in play.

  Adapters receive fully-resolved options rather than reading configuration
  themselves, which keeps them close to pure functions: same inputs, same
  behaviour, no ambient state.
  """

  alias JobRunner.LLM.Error

  @typedoc "A single chat message. Roles follow the OpenAI convention."
  @type message :: %{role: :system | :user | :assistant, content: String.t()}

  @typedoc """
  Resolved call options. Adapters receive these already merged from application
  config and any per-call overrides.
  """
  @type opts :: keyword()

  @typedoc "Either the assistant's text, or a normalised failure."
  @type response :: {:ok, String.t()} | {:error, Error.t()}

  @doc """
  Perform one chat completion. Implementations must:

    * return `{:ok, text}` only for a non-empty assistant message;
    * translate every anticipated failure into `{:error, %Error{}}` rather than
      raising — a raised exception is treated as a bug, not a provider failure;
    * perform exactly **one** attempt. An adapter that retried internally would
      multiply the configured budget and hold a concurrency slot while it did.
  """
  @callback chat(messages :: [message()], opts :: opts()) :: response()

  @doc """
  Call the configured adapter.

  `overrides` are merged over the application config, which is what lets a test
  point a single call at a different base URL without touching global state.
  """
  @spec chat([message()], opts()) :: response()
  def chat(messages, overrides \\ []) do
    opts = config(overrides)
    {adapter, opts} = Keyword.pop!(opts, :adapter)

    adapter.chat(messages, opts)
  end

  @doc """
  The resolved LLM configuration, with `overrides` applied.

  Exposed so the dashboard and `mix` tasks can display which provider is live
  without duplicating the merge logic.
  """
  @spec config(opts()) :: opts()
  def config(overrides \\ []) do
    :job_runner
    |> Application.get_env(:llm, [])
    |> Keyword.merge(overrides)
  end

  @doc """
  A one-line summary of the resolved provider, for IEx and the dashboard.

  Config arrives through four layers — `config.exs` defaults, an `LLM_PROVIDER`
  profile, individual `LLM_*` variables, then per-call options — so "what is it
  actually talking to?" is a genuinely hard question to answer by reading files.
  This answers it from the resolved values, with the key redacted.
  """
  @spec describe(opts()) :: String.t()
  def describe(overrides \\ []) do
    cfg = config(overrides)

    "#{cfg[:base_url]} model=#{cfg[:model]} adapter=#{inspect(cfg[:adapter])} " <>
      "token_param=#{inspect(cfg[:token_param])} " <>
      "key=#{if cfg[:api_key] in [nil, "", "not-required"], do: "none", else: "set"}"
  end

  @doc """
  Convenience for the common single-prompt case.

  Most jobs are one system message plus one user message; this saves every
  caller from hand-rolling the same list.
  """
  @spec messages(String.t(), String.t() | nil) :: [message()]
  def messages(prompt, system \\ nil)

  def messages(prompt, nil), do: [%{role: :user, content: prompt}]

  def messages(prompt, system) do
    [%{role: :system, content: system}, %{role: :user, content: prompt}]
  end
end
