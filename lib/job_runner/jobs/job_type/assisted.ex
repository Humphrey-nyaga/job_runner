defmodule JobRunner.Jobs.JobType.Assisted do
  @moduledoc """

  The model gets a small menu of read-only Elixir functions
  (`JobRunner.Jobs.Tools`) and replies with either an answer or a tool request.
  If it asks, the Worker runs the tool and sends the result back in a follow-up
  prompt; the second reply must be an answer.

  """

  @behaviour JobRunner.Jobs.JobType

  alias JobRunner.Jobs.{Job, JobType, Tools}
  alias JobRunner.LLM

  @impl true
  def messages(%Job{prompt: prompt}) do
    LLM.messages(prompt, system())
  end

  defp system do
    """
    You answer questions. You may call at most ONE tool if you need live data.

    Tools available:
    #{Tools.describe()}

    Respond with a single JSON object and nothing else. No prose, no code fence.

    To call a tool:   {"tool": "<tool name>"}
    To answer:        {"answer": "<your answer>"}

    Only call a tool when you genuinely need it. If you can answer directly, do.
    """
  end

  @doc """
  Messages for the second round, after a tool has run.

  The first response is replayed as an assistant turn so the model sees its own
  request, then the tool output arrives as a user turn.
  """
  @spec follow_up(Job.t(), String.t(), String.t(), String.t()) :: [LLM.message()]
  def follow_up(%Job{prompt: prompt}, tool, result, first_response) do
    [
      %{role: :system, content: system()},
      %{role: :user, content: prompt},
      %{role: :assistant, content: first_response},
      %{
        role: :user,
        content: """
        Tool `#{tool}` returned:

        #{result}

        Now answer the original question using this. Respond with {"answer": "..."} only.
        """
      }
    ]
  end

  @impl true
  def parse(text) do
    with {:ok, object} <- JobType.extract_json(text) do
      case object do
        %{"answer" => answer} when is_binary(answer) ->
          case String.trim(answer) do
            "" -> {:error, {:invalid_shape, "answer was empty"}}
            trimmed -> {:ok, trimmed}
          end

        %{"tool" => tool} when is_binary(tool) ->
          # Validated against the whitelist here
          if tool in Tools.names() do
            {:tool_call, tool}
          else
            {:error, {:invalid_shape, "unknown tool #{inspect(tool)}"}}
          end

        _ ->
          {:error, {:invalid_shape, "expected an \"answer\" or \"tool\" key"}}
      end
    end
  end

  @impl true
  def llm_opts, do: [response_format: %{type: "json_object"}]
end
