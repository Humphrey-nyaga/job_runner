defmodule JobRunner.LLM.Mock do
  @moduledoc """
  Scripted `JobRunner.LLM` implementation for tests and demos.

  The engine's interesting behaviour is *failure* behaviour, which cannot be
  reproduced on demand against a live endpoint. This adapter can, and satisfies
  the same behaviour as the real one, so the engine cannot tell them apart.

  The script is consumed one entry per call and the last entry repeats forever,
  so "always fails" is a one-element script rather than a guess at how many
  attempts the engine will make. Entries may be `{:ok, text}`,
  `{:error, %Error{}}`, `{:sleep, ms, entry}` or `{:raise, message}`.

  State lives in one named Agent, so tests using it must run `async: false`.
  """

  @behaviour JobRunner.LLM

  use Agent

  alias JobRunner.LLM.Error

  @type entry ::
          {:ok, String.t()}
          | {:error, Error.t()}
          | {:sleep, non_neg_integer(), entry()}
          | {:raise, String.t()}

  defstruct script: [{:ok, "mock response"}], calls: []

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %__MODULE__{} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Replace the script and clear the recorded call log."
  @spec script([entry()]) :: :ok
  def script(entries) when is_list(entries) and entries != [] do
    Agent.update(__MODULE__, fn _ -> %__MODULE__{script: entries, calls: []} end)
  end

  @doc "Every call made so far, oldest first, as `{messages, opts}` pairs."
  @spec calls() :: [{[JobRunner.LLM.message()], keyword()}]
  def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()

  @doc "How many times the adapter has been called. Used to assert attempt budgets."
  @spec call_count() :: non_neg_integer()
  def call_count, do: Agent.get(__MODULE__, &length(&1.calls))

  @doc "Clear the call log without changing the script."
  @spec reset_calls() :: :ok
  def reset_calls, do: Agent.update(__MODULE__, &%{&1 | calls: []})

  @impl JobRunner.LLM
  def chat(messages, opts) do
    # Recording and popping happen in one update so that concurrent callers
    # cannot both take the same script entry.
    entry =
      Agent.get_and_update(__MODULE__, fn state ->
        {entry, remaining} = next(state.script)
        {entry, %{state | script: remaining, calls: [{messages, opts} | state.calls]}}
      end)

    interpret(entry)
  end

  # The last entry is sticky: a one-element script means "always this".
  defp next([last]), do: {last, [last]}
  defp next([head | tail]), do: {head, tail}

  defp interpret({:sleep, ms, entry}) do
    Process.sleep(ms)
    interpret(entry)
  end

  defp interpret({:raise, message}), do: raise(message)
  defp interpret({:ok, _text} = ok), do: ok
  defp interpret({:error, %Error{}} = error), do: error
end
