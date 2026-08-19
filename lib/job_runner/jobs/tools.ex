defmodule JobRunner.Jobs.Tools do
  @moduledoc """
  Local functions a model may ask the system to run.

  The model supplies a *name*, and a name is untrusted input that the job's own
  prompt can influence. Names are matched against a closed map and never
  resolved into a function: `String.to_existing_atom/1` plus `apply/3` here
  would be remote code execution chosen by model output.

  Tools are zero-arity and read-only, so the model chooses only whether one
  runs, never what it operates on. The Worker permits one tool round per
  attempt.
  """

  alias JobRunner.Jobs

  @tools %{
    "get_time" => %{
      description: "The current UTC date and time in ISO 8601 format.",
      run: &__MODULE__.get_time/0
    },
    "job_stats" => %{
      description: "How many jobs this system has pending, running, completed and failed.",
      run: &__MODULE__.job_stats/0
    }
  }

  @doc "Names and descriptions, for building the system prompt."
  @spec describe() :: String.t()
  def describe do
    Enum.map_join(@tools, "\n", fn {name, %{description: description}} ->
      "  #{name} — #{description}"
    end)
  end

  @spec names() :: [String.t()]
  def names, do: Map.keys(@tools)

  @doc """
  Run a tool by name.

  Returns `{:error, :unknown_tool}` for anything outside the whitelist,
  including valid function names elsewhere in the system.
  A raising tool is caught and reported, so a broken tool surfaces as a failed
  job with a readable reason rather than an unexplained task exit.
  """
  @spec invoke(String.t()) ::
          {:ok, String.t()} | {:error, :unknown_tool | {:tool_failed, String.t()}}
  def invoke(name) when is_binary(name) do
    case Map.fetch(@tools, name) do
      {:ok, %{run: run}} ->
        try do
          {:ok, to_string(run.())}
        rescue
          exception -> {:error, {:tool_failed, Exception.message(exception)}}
        end

      :error ->
        {:error, :unknown_tool}
    end
  end

  def invoke(_), do: {:error, :unknown_tool}

  @doc false
  def get_time, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc false
  def job_stats do
    stats = Jobs.stats()

    "pending=#{stats.pending} running=#{stats.running} " <>
      "completed=#{stats.completed} failed=#{stats.failed}"
  end
end
