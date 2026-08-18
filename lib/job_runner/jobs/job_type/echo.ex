defmodule JobRunner.Jobs.JobType.Echo do
  @moduledoc """
  The simplest job: send the prompt, keep the text.

  Useful as the default, and as the control case — if an Echo job fails, the
  problem is the endpoint or the engine, never the parsing.
  """

  @behaviour JobRunner.Jobs.JobType

  alias JobRunner.Jobs.Job
  alias JobRunner.LLM

  @impl true
  def messages(%Job{prompt: prompt}), do: LLM.messages(prompt)

  @impl true
  def parse(text) when is_binary(text), do: {:ok, text}

  @impl true
  def llm_opts, do: []
end
